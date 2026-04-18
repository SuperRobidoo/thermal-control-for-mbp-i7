//
//  ThermalMonitor.swift
//  Thermal Control
//

import Foundation

// MARK: - Logger

private func tcLog(_ msg: String, file: String = #file, line: Int = #line) {
    let f = (file as NSString).lastPathComponent
    print("[ThermalControl:\(f):\(line)] \(msg)")
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

    private let service = PowerMetricsService()
    private let notificationManager = NotificationManager.shared
    private let maxHistoryDuration: TimeInterval = 3 * 60 * 60 // 3 hours
    private var saveTimer: Timer?

    let fanController = SMCFanController()

    private static var historyFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Thermal Control", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    func start() {
        tcLog("ThermalMonitor.start() called")
        loadHistory()
        isRunning = true
        needsPrivilegeSetup = false
        service.onSample = { [weak self] sample in
            DispatchQueue.main.async { self?.handle(sample: sample) }
        }
        service.onError = { [weak self] msg in
            tcLog("ThermalMonitor: service.onError → \(msg)")
            DispatchQueue.main.async {
                self?.errorMessage = msg
                self?.isRunning = false
            }
        }
        service.onPermissionRequired = { [weak self] in
            tcLog("ThermalMonitor: service.onPermissionRequired fired")
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.needsPrivilegeSetup = true
            }
        }
        service.start()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.saveHistory()
        }
    }

    /// One-time setup: writes a sudoers.d entry so powermetrics and the fan helper
    /// run without password. Also installs the bundled fan helper to /usr/local/bin.
    /// Shows the standard macOS admin authentication dialog.
    func setupPrivileges(completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let user = NSUserName()
            let helperInstall = SMCFanController.helperInstallPath
            let sudoersLine   = "\(user) ALL=(root) NOPASSWD: /usr/bin/powermetrics, \(helperInstall)"

            // Locate the bundled fan helper
            let bundledHelper = Bundle.main.url(forResource: "tc-fan-helper", withExtension: nil)?.path ?? ""
            let installCmd: String
            if !bundledHelper.isEmpty {
                installCmd = "mkdir -p /usr/local/bin && cp '\(bundledHelper)' '\(helperInstall)' && chmod 755 '\(helperInstall)' && "
            } else {
                installCmd = ""
            }

            let script = """
            do shell script "\(installCmd)printf '%s\\n' '\(sudoersLine)' > /etc/sudoers.d/thermalcontrol && chmod 440 /etc/sudoers.d/thermalcontrol" with administrator privileges
            """
            var appleScriptError: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else {
                DispatchQueue.main.async { completion(false, "Could not create AppleScript.") }
                return
            }
            appleScript.executeAndReturnError(&appleScriptError)
            if let err = appleScriptError {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                DispatchQueue.main.async { completion(false, msg) }
            } else {
                DispatchQueue.main.async {
                    tcLog("ThermalMonitor: sudoers written — setting up and starting")
                    self.needsPrivilegeSetup = false
                    self.isRunning = true
                    // Skip permission re-check — sudoers entry was just written
                    self.service.startAfterPrivilegesGranted()
                    // Activate fan controller now that helper is installed
                    self.fanController.refreshAvailability()
                    completion(true, nil)
                }
            }
        }
    }

    func stop() {
        tcLog("ThermalMonitor.stop() called")
        // Restore automatic fan control before quitting
        if fanController.isManual {
            fanController.setAuto()
        }
        service.stop()
        isRunning = false
        saveTimer?.invalidate()
        saveHistory()
    }

    private func handle(sample: RawThermalSample) {
        tcLog("ThermalMonitor.handle(sample:): cpu=\(sample.cpuTemperature)°C pressure=\(sample.thermalPressure) fan=\(sample.fanRPM)rpm")
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

        let reading = TemperatureReading(
            timestamp: Date(),
            cpuTemperature: sample.cpuTemperature,
            thermalPressure: sample.thermalPressure,
            isThrottling: pressure.isThrottling,
            cpuThermalLevel: sample.cpuThermalLevel,
            gpuThermalLevel: sample.gpuThermalLevel,
            ioThermalLevel: sample.ioThermalLevel,
            fanRPM: sample.fanRPM,
            gpuTemperature: sample.gpuTemperature,
            cpuPLimit: sample.cpuPLimit,
            gpuPLimitInt: sample.gpuPLimitInt,
            gpuPLimitExt: sample.gpuPLimitExt,
            prochotCount: sample.prochotCount
        )
        recentReadings.append(reading)

        // Prune readings older than 3 hours
        let cutoff = Date().addingTimeInterval(-maxHistoryDuration)
        recentReadings.removeAll { $0.timestamp < cutoff }

        if !wasThrottling && isThrottling {
            notificationManager.sendThrottleAlert(pressure: pressure)
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
