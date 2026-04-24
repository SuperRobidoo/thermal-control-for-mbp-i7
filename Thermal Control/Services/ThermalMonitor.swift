//
//  ThermalMonitor.swift
//  Thermal Control
//

import Foundation
import LocalAuthentication
import AppKit
import os.log

// MARK: - Loggers

private let monitorLog = Logger(subsystem: "com.thermalcontrol", category: "monitor")
private let safetyLog  = Logger(subsystem: "com.thermalcontrol", category: "safety")

@available(*, deprecated, message: "Use monitorLog or safetyLog instead")
private func tcLog(_ msg: String, file: String = #file, line: Int = #line) {
    let f = (file as NSString).lastPathComponent
    monitorLog.debug("\(f, privacy: .public):\(line, privacy: .public) \(msg, privacy: .public)")
}

enum ThermalPressure: String, CaseIterable, Codable {
    case nominal = "Nominal"
    case moderate = "Moderate"
    case heavy = "Heavy"
    case trapping = "Trapping"

    var isThrottling: Bool { self != .nominal }

    var displayName: String { rawValue }

    var severity: Int {
        switch self {
        case .nominal: return 0
        case .moderate: return 1
        case .heavy: return 2
        case .trapping: return 3
        }
    }
}

final class ThermalMonitor: ObservableObject {
    @Published var currentTemperature: Double = 0.0
    @Published var currentPressure: ThermalPressure = .nominal
    @Published var isThrottling: Bool = false
    @Published var recentReadings: [TemperatureReading] = []
    @Published var isRunning: Bool = false
    @Published var errorMessage: String? = nil
    @Published var needsPrivilegeSetup: Bool = false

    // Extended SMC metrics
    @Published var cpuThermalLevel: Int = 0
    @Published var gpuThermalLevel: Int = 0
    @Published var ioThermalLevel: Int = 0
    @Published var fanRPM: Int = 0
    @Published var gpuTemperature: Double = 0.0
    @Published var cpuPLimit: Double = 0.0
    @Published var gpuPLimitInt: Double = 0.0
    @Published var gpuPLimitExt: Double = 0.0
    @Published var prochotCount: Int = 0
    // cpu_power sampler metrics
    @Published var packagePowerW: Double = 0.0
    @Published var cpuFreqNominalPct: Double = 0.0
    @Published var coresActivePct: Double = 0.0
    @Published var gpuActivePct: Double = 0.0

    private let service = PowerMetricsService()
    private let notificationManager = NotificationManager.shared
    private let maxHistoryDuration: TimeInterval = 3 * 60 * 60 // 3 hours
    private var saveTimer: Timer?
    private var wakeObserver: Any?

    // MARK: - Thermal safety state

    // i7-7567U: Tj,max = 100°C.
    // Warning fires at 97°C to allow time for fan ramp before junction max.
    private static let emergencyTempThreshold: Double = 97.0
    private static let criticalTempThreshold:  Double = 100.0
    private static let emergencyHysteresis:    Double = 5.0   // °C below threshold before releasing
    // Notification guards — prevent repeated alerts for the same thermal episode.
    private var emergencyAlertSent = false
    private var criticalAlertSent  = false

    // Fan-stall detection (monitor-only; no fan commands issued)
    private static let fanStallRPMThreshold:  Int    = 300
    private static let fanStallTempThreshold: Double = 45.0
    private static let fanStallConfirmCount:  Int    = 3
    private var fanStallCount = 0

    // Sample-stream watchdog
    private static let sampleStalenessThreshold: TimeInterval = 10.0
    private var lastSampleDate: Date = .distantPast
    private var watchdogTimer: Timer?

    let fanController = SMCFanController()

    private static var historyFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Thermal Control", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    deinit {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    func start() {
        monitorLog.info("ThermalMonitor.start() called")
        // If the service process is already alive (e.g. window was closed but app kept running),
        // just make sure isRunning is set and bail out.
        if service.isProcessRunning {
            monitorLog.info("ThermalMonitor.start(): process already running — skipping restart")
            isRunning = true
            return
        }
        loadHistory()
        isRunning = true
        needsPrivilegeSetup = false
        service.onSample = { [weak self] sample in
            DispatchQueue.main.async { self?.handle(sample: sample) }
        }
        service.onError = { [weak self] msg in
            monitorLog.error("ThermalMonitor: service.onError → \(msg, privacy: .public)")
            DispatchQueue.main.async {
                self?.errorMessage = msg
                self?.isRunning = false
            }
        }
        service.onPermissionRequired = { [weak self] in
            monitorLog.warning("ThermalMonitor: service.onPermissionRequired fired")
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.needsPrivilegeSetup = true
            }
        }
        service.start()
        lastSampleDate = Date()  // initialise so watchdog doesn't fire immediately
        startWatchdog()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.handleSystemWake() }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.saveHistory()
        }
    }

    /// One-time setup: authenticates via Touch ID / Apple Watch / password, then writes
    /// the sudoers entry and installs the fan helper — no separate password dialog needed.
    func setupPrivileges(completion: @escaping (Bool, String?) -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        var laError: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &laError) else {
            // LocalAuthentication completely unavailable — fall back to AppleScript dialog
            setupPrivilegesWithAppleScript(completion: completion)
            return
        }

        let reason = "Thermal Control needs one-time administrator access to monitor CPU temperatures without asking for a password each time."
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, authError in
            guard let self else { return }
            if success {
                self.setupPrivilegesWithAppleScript(completion: completion)
            } else {
                // User cancelled or auth failed — fall back to AppleScript as safety net
                let msg = (authError as NSError?)?.localizedDescription ?? "Authentication was cancelled."
                // If biometric was cancelled deliberately, don't fall through; report it
                if let laErr = authError as? LAError, laErr.code == .userCancel || laErr.code == .appCancel {
                    DispatchQueue.main.async { completion(false, msg) }
                } else {
                    self.setupPrivilegesWithAppleScript(completion: completion)
                }
            }
        }
    }

    // MARK: - Privilege helpers

    // MARK: - Privilege helpers

    /// AppleScript privilege escalation (shows system admin dialog with Touch ID/Watch on supported hardware).
    private func setupPrivilegesWithAppleScript(completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = self.buildSetupScript()
            let appleScriptSource = """
            do shell script "\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))" with administrator privileges
            """
            var appleScriptError: NSDictionary?
            guard let appleScript = NSAppleScript(source: appleScriptSource) else {
                DispatchQueue.main.async { completion(false, "Could not create AppleScript.") }
                return
            }
            appleScript.executeAndReturnError(&appleScriptError)
            if let err = appleScriptError {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                DispatchQueue.main.async { completion(false, msg) }
            } else {
                DispatchQueue.main.async { self.finishPrivilegeSetup(completion: completion) }
            }
        }
    }

    private func buildSetupScript() -> String {
        let user = NSUserName()
        let helperInstall = SMCFanController.helperInstallPath
        let sudoersLine = "\(user) ALL=(root) NOPASSWD: /usr/bin/powermetrics, \(helperInstall)"
        let bundledHelper = Bundle.main.url(forResource: "tc-fan-helper", withExtension: nil)?.path ?? ""
        // Shell-escape single quotes so paths containing apostrophes (e.g. "User's Apps")
        // don't break the single-quoted shell arguments. Replace ' with '\''
        let escapedHelper  = bundledHelper.replacingOccurrences(of: "'", with: "'\\''")
        let escapedInstall = helperInstall.replacingOccurrences(of: "'", with: "'\\''")
        let installPart = bundledHelper.isEmpty ? "" :
            "mkdir -p /usr/local/bin && cp '\(escapedHelper)' '\(escapedInstall)' && chmod 755 '\(escapedInstall)' && "
        return "\(installPart)printf '%s\\n' '\(sudoersLine)' > /etc/sudoers.d/thermalcontrol && chmod 440 /etc/sudoers.d/thermalcontrol"
    }

    private func finishPrivilegeSetup(completion: @escaping (Bool, String?) -> Void) {
        monitorLog.info("ThermalMonitor: privileged setup complete")
        needsPrivilegeSetup = false
        isRunning = true
        lastSampleDate = Date()
        service.startAfterPrivilegesGranted()
        startWatchdog()
        fanController.refreshAvailability()
        completion(true, nil)
    }

    func stop() {
        monitorLog.info("ThermalMonitor.stop() called")
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        service.stop()
        isRunning = false
        saveTimer?.invalidate()
        saveHistory()
    }

    private func handle(sample: RawThermalSample) {
        monitorLog.debug("handle(sample:): cpu=\(sample.cpuTemperature, privacy: .public)°C pressure=\(sample.thermalPressure, privacy: .public) fan=\(sample.fanRPM, privacy: .public)rpm")

        // Stamp receipt time so the watchdog can detect a stale stream.
        lastSampleDate = Date()

        // Clear any stale-stream or restart error banner now that data is flowing.
        if errorMessage != nil { errorMessage = nil }

        // ── Fan-stall check (runs before any control logic) ──────────────────
        checkFanStall(fanRPM: sample.fanRPM, cpuTemp: sample.cpuTemperature)

        // ── Emergency thermal ceiling ─────────────────────────────────────────
        if sample.cpuTemperature >= Self.criticalTempThreshold {
            if !criticalAlertSent {
                criticalAlertSent = true
                safetyLog.critical("CPU \(sample.cpuTemperature, privacy: .public)°C ≥ Tj,max \(Self.criticalTempThreshold). Requesting system sleep.")
                notificationManager.sendCriticalOverheatAlert(temp: sample.cpuTemperature)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if let script = NSAppleScript(source: "tell application \"System Events\" to sleep") {
                        script.executeAndReturnError(nil)
                    }
                }
            }
        } else {
            criticalAlertSent = false

            if sample.cpuTemperature >= Self.emergencyTempThreshold {
                if !emergencyAlertSent {
                    emergencyAlertSent = true
                    safetyLog.error("CPU \(sample.cpuTemperature, privacy: .public)°C ≥ emergency threshold \(Self.emergencyTempThreshold).")
                    notificationManager.sendOverheatWarning(temp: sample.cpuTemperature)
                }
            } else if emergencyAlertSent &&
                      sample.cpuTemperature < (Self.emergencyTempThreshold - Self.emergencyHysteresis) {
                emergencyAlertSent = false
                safetyLog.info("CPU recovered to \(sample.cpuTemperature, privacy: .public)°C.")
            }
        }

        let pressure = ThermalPressure(rawValue: sample.thermalPressure) ?? .nominal
        let wasThrottling = isThrottling
        currentTemperature = sample.cpuTemperature
        currentPressure = pressure
        isThrottling = pressure.isThrottling

        // Extended metrics
        cpuThermalLevel = sample.cpuThermalLevel
        gpuThermalLevel = sample.gpuThermalLevel
        ioThermalLevel  = sample.ioThermalLevel
        fanRPM          = sample.fanRPM
        gpuTemperature  = sample.gpuTemperature
        cpuPLimit       = sample.cpuPLimit
        gpuPLimitInt    = sample.gpuPLimitInt
        gpuPLimitExt    = sample.gpuPLimitExt
        prochotCount    = sample.prochotCount
        packagePowerW     = sample.packagePowerW
        cpuFreqNominalPct = sample.cpuFreqNominalPct
        coresActivePct    = sample.coresActivePct
        gpuActivePct      = sample.gpuActivePct

        let reading = TemperatureReading(
            timestamp:        Date(),
            cpuTemperature:   sample.cpuTemperature,
            thermalPressure:  sample.thermalPressure,
            isThrottling:     pressure.isThrottling,
            cpuThermalLevel:  sample.cpuThermalLevel,
            gpuThermalLevel:  sample.gpuThermalLevel,
            ioThermalLevel:   sample.ioThermalLevel,
            fanRPM:           sample.fanRPM,
            gpuTemperature:   sample.gpuTemperature,
            cpuPLimit:        sample.cpuPLimit,
            gpuPLimitInt:     sample.gpuPLimitInt,
            gpuPLimitExt:     sample.gpuPLimitExt,
            prochotCount:     sample.prochotCount,
            packagePowerW:    sample.packagePowerW,
            cpuFreqNominalPct: sample.cpuFreqNominalPct,
            coresActivePct:   sample.coresActivePct,
            gpuActivePct:     sample.gpuActivePct
        )
        recentReadings.append(reading)

        // Prune readings older than 3 hours
        let cutoff = Date().addingTimeInterval(-maxHistoryDuration)
        recentReadings.removeAll { $0.timestamp < cutoff }

        if !wasThrottling && isThrottling {
            notificationManager.sendThrottleAlert(pressure: pressure)
        }
    }

    // MARK: - Fan-stall detection

    /// Logs a suspected fan stall when RPM is extremely low while CPU is warm.
    /// No fan commands are issued — detection only.
    private func checkFanStall(fanRPM: Int, cpuTemp: Double) {
        if fanRPM < Self.fanStallRPMThreshold && cpuTemp > Self.fanStallTempThreshold {
            fanStallCount += 1
            safetyLog.error("Fan stall suspected: RPM=\(fanRPM, privacy: .public) at \(cpuTemp, privacy: .public)°C (consecutive=\(self.fanStallCount, privacy: .public))")
            if fanStallCount >= Self.fanStallConfirmCount {
                safetyLog.critical("Fan stall confirmed after \(self.fanStallCount, privacy: .public) samples")
                notificationManager.sendFanStallAlert(rpm: fanRPM, temp: cpuTemp)
                fanStallCount = 0
            }
        } else {
            fanStallCount = 0
        }
    }

    // MARK: - Sample-stream watchdog

    /// Called immediately when macOS wakes from sleep — proactively restarts the
    /// powermetrics service instead of waiting for the watchdog to detect staleness.
    private func handleSystemWake() {
        monitorLog.info("System woke from sleep — restarting thermal service")
        errorMessage = nil
        lastSampleDate = Date()   // keep watchdog calm during the restart gap
        service.stop()
        service.startAfterPrivilegesGranted()
    }

    /// Starts (or restarts) the watchdog timer that detects a stale powermetrics stream.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let age = Date().timeIntervalSince(self.lastSampleDate)
            guard age > Self.sampleStalenessThreshold else { return }

            safetyLog.warning("No thermal sample for \(age, privacy: .public) s — stream stale. Restarting service.")
            DispatchQueue.main.async {
                self.errorMessage = "Sensor data stale (\(Int(age))s) — restarting monitor…"
                self.lastSampleDate = Date()  // reset to prevent re-entry before restart completes
                self.service.stop()
                self.service.startAfterPrivilegesGranted()
            }
        }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyFileURL),
              let readings = try? JSONDecoder().decode([TemperatureReading].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-maxHistoryDuration)
        recentReadings = readings.filter { $0.timestamp >= cutoff }
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(recentReadings) else { return }
        try? data.write(to: Self.historyFileURL, options: .atomic)
    }
}
