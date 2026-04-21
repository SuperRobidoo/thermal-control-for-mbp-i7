//
//  SMCFanController.swift
//  Thermal Control
//
//  Manages manual fan speed control via the bundled tc-fan-helper binary.
//  Write operations require root — the helper is invoked with sudo -n,
//  relying on the NOPASSWD sudoers entry written during privilege setup.
//

import Foundation
import CryptoKit
import os.log

private let fanLog = Logger(subsystem: "com.thermalcontrol", category: "fan")

// MARK: - Fan control mode

enum FanControlMode: Equatable {
    /// SMC firmware decides fan speed automatically.
    case auto
    /// App aggressively pre-spins the fan to prevent thermal throttling.
    case optimized
    /// User has set a fixed target RPM.
    case manual
}

// MARK: - Controller

final class SMCFanController: ObservableObject {

    static let helperInstallPath = "/usr/local/bin/tc-fan-helper"

    // MBP 2017 physical fan envelope (covers both 13" and 15" variants).
    // These are hard limits applied regardless of what the SMC reports.
    static let absoluteMinRPM: Double = 1200
    static let absoluteMaxRPM: Double = 6200

    // Maximum RPM change per second when slewing toward a target.
    // ~350 RPM/s matches Apple's observed auto-mode ramp rate and avoids
    // motor-controller current spikes on the MBP 2017 Nidec fans.
    private static let maxSlewRateRPMPerSec: Double = 350.0

    // SHA-256 of the release tc-fan-helper binary.
    // Update this constant whenever the helper is rebuilt.
    // Set to empty string to disable the check during development.
    static var expectedHelperSHA256: String = ""

    @Published var isAvailable: Bool = false
    @Published var mode: FanControlMode = .auto
    @Published var isManual: Bool = false   // true when SMC is in manual override
    @Published var targetRPM: Double = 0
    @Published var minRPM: Double = 2000
    @Published var maxRPM: Double = 6200
    @Published var fanCount: Int = 2
    /// RPM the optimized algorithm last commanded (shown in UI).
    @Published var optimizedTargetRPM: Double = 0

    private var optimizedLastSetRPM: Double = 0
    // EMA state for input smoothing — reduces fan chatter from momentary spikes.
    private var smoothedPowerW: Double = 0    // EMA of packagePowerW (α=0.30)
    private var smoothedF: Double      = 0    // EMA of aggregated factor (α=0.20)
    private var lastApplyTime: Date = .distantPast
    private var lastAppliedRPM: Double = 0

    init() {
        refreshAvailability()
    }

    func refreshAvailability() {
        let fm = FileManager.default
        let exists     = fm.fileExists(atPath: Self.helperInstallPath)
        let executable = fm.isExecutableFile(atPath: Self.helperInstallPath)
        let trusted    = helperIntegrityCheck()
        isAvailable = exists && executable && trusted
        if isAvailable { readState() }
    }

    /// Verify the installed helper binary matches the expected SHA-256 digest.
    /// Returns `true` when the expected hash is not configured (development mode)
    /// or when the digest matches.
    private func helperIntegrityCheck() -> Bool {
        guard !Self.expectedHelperSHA256.isEmpty else { return true }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.helperInstallPath)),
              !data.isEmpty else { return false }
        let digest = SHA256.hash(data: data)
        let hex    = digest.map { String(format: "%02x", $0) }.joined()
        let ok     = hex == Self.expectedHelperSHA256
        if !ok {
            fanLog.critical("Helper integrity check FAILED: got \(hex, privacy: .public), expected \(Self.expectedHelperSHA256, privacy: .public)")
        }
        return ok
    }

    /// Read current fan mode, target, min, and max from SMC.
    func readState() {
        runHelper(args: ["get"]) { [weak self] output in
            guard let self, let output else { return }
            // "rpm=2001 min=2000 max=5700 manual=0 target=0 fans=2"
            var manual = 0
            var currentRPM: Double = 0
            var target: Double = 0
            var minR: Double = 2000
            var maxR: Double = 6200
            var fans = 2
            for pair in output.components(separatedBy: " ") {
                let kv = pair.components(separatedBy: "=")
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "rpm":    currentRPM = Double(kv[1]) ?? 0
                case "min":    minR   = Double(kv[1]) ?? 2000
                case "max":    maxR   = Double(kv[1]) ?? 6200
                case "manual": manual = Int(kv[1]) ?? 0
                case "target": target = Double(kv[1]) ?? 0
                case "fans":   fans   = Int(kv[1]) ?? 2
                default: break
                }
            }
            // Clamp SMC-reported limits to known-safe hardware constants.
            // Protects against corrupt SMC responses (e.g. 0 or 65535).
            let rawMin = minR, rawMax = maxR
            minR = minR.clamped(Self.absoluteMinRPM, Self.absoluteMaxRPM)
            maxR = maxR.clamped(minR, Self.absoluteMaxRPM)
            if rawMin != minR || rawMax != maxR {
                fanLog.warning("SMC-reported limits out of safe range (min=\(rawMin, privacy: .public) max=\(rawMax, privacy: .public)) — clamped to min=\(minR, privacy: .public) max=\(maxR, privacy: .public)")
            }

            // Seed the slew-limiter from the actual current fan RPM so that the
            // optimized-mode dead-band check starts from reality, not from zero.
            if currentRPM > 0 {
                self.lastAppliedRPM = currentRPM.clamped(Self.absoluteMinRPM, Self.absoluteMaxRPM)
            }

            // If the SMC is in manual mode but the app is in auto mode, a previous
            // session likely exited uncleanly and left the SMC locked.
            // Release it immediately so macOS firmware regains control.
            if manual == 1 && self.mode == .auto {
                fanLog.warning("SMC manual override detected on startup (RPM=\(currentRPM, privacy: .public)) — releasing orphaned lock")
                self.setAuto(onError: { err in
                    fanLog.error("Failed to release orphaned SMC manual lock: \(err, privacy: .public)")
                })
                return
            }

            DispatchQueue.main.async {
                self.minRPM    = minR
                self.maxRPM    = maxR
                self.isManual  = manual == 1
                self.targetRPM = (target > 0) ? target : minR
                self.fanCount  = fans
            }
        }
    }

    // MARK: - Mode switching

    /// Switch fans back to automatic SMC control.
    /// - Parameter onError: Called on the main queue if the helper fails after one retry.
    func setAuto(onError: ((String) -> Void)? = nil, completion: ((Bool) -> Void)? = nil) {
        mode = .auto
        optimizedLastSetRPM = 0
        smoothedPowerW = 0
        smoothedF      = 0
        attemptSetAuto(retryCount: 0, onError: onError, completion: completion)
    }

    private func attemptSetAuto(retryCount: Int, onError: ((String) -> Void)?, completion: ((Bool) -> Void)?) {
        runHelper(args: ["auto"]) { [weak self] output in
            guard let self else { return }
            let ok = output?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
            if ok {
                DispatchQueue.main.async {
                    self.isManual = false
                    completion?(true)
                }
            } else if retryCount == 0 {
                // One automatic retry after a short delay before surfacing the error.
                fanLog.warning("setAuto: helper did not return 'ok' — retrying once")
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    self.attemptSetAuto(retryCount: 1, onError: onError, completion: completion)
                }
            } else {
                let msg = "Could not release SMC manual override after retry (output: \(output ?? "nil")). Fan may still be manually controlled. Try switching to Auto again."
                fanLog.error("\(msg, privacy: .public)")
                DispatchQueue.main.async {
                    onError?(msg)
                    completion?(false)
                }
            }
        }
    }

    /// Enter optimized mode — first sample will set the initial RPM.
    func setOptimizedMode() {
        mode = .optimized
        // Seed to current lastAppliedRPM so the ramp-down check has the right
        // baseline on entry (fan may be anywhere depending on what mode we came from).
        optimizedLastSetRPM = lastAppliedRPM
        smoothedPowerW = 0
        smoothedF      = 0
    }

    /// Set a manual target RPM for all fans.
    func setManual(rpm: Double, completion: ((Bool) -> Void)? = nil) {
        if mode != .optimized { mode = .manual }
        applyRPM(rpm, completion: completion)
    }

    // MARK: - Optimized algorithm

    /// Called on every new thermal sample when mode == .optimized.
    func updateOptimizedMode(cpuTemp: Double, cpuThermalLevel: Int,
                             gpuTemp: Double, gpuThermalLevel: Int,
                             packagePowerW: Double,
                             isThrottling: Bool) {
        guard mode == .optimized else { return }
        let target = calculateOptimizedRPM(cpuTemp: cpuTemp,
                                           cpuThermalLevel: cpuThermalLevel,
                                           gpuTemp: gpuTemp,
                                           gpuThermalLevel: gpuThermalLevel,
                                           packagePowerW: packagePowerW,
                                           isThrottling: isThrottling)
        DispatchQueue.main.async { self.optimizedTargetRPM = target }

        // Two independent dead-band checks using different reference points:
        //
        // Ramp UP  — compared against optimizedLastSetRPM (the last *decision*).
        //   Prevents commanding a higher speed on every sample during a gradual
        //   temperature rise; only fires when the target has meaningfully grown
        //   past the last set point.
        //
        // Ramp DOWN — compared against lastAppliedRPM (what the fan actually
        //   received after slew limiting).  This is what was missing: after an
        //   emergency/throttle event the slew limiter leaves the fan at an
        //   intermediate RPM well above the new target, but optimizedLastSetRPM
        //   diverges from that, so the old delta check blocked all further
        //   ramp-down commands — fan got stuck in high gear.
        let shouldRampUp   = target > optimizedLastSetRPM + 300
        let shouldRampDown = lastAppliedRPM > 0 && target < lastAppliedRPM - 800
        guard shouldRampUp || shouldRampDown else { return }
        optimizedLastSetRPM = target
        applyRPM(target)
    }

    /// Called by ThermalMonitor when the emergency fan-max override is released.
    /// Seeds optimizedLastSetRPM to maxRPM so the ramp-down check fires
    /// immediately on the next sample rather than waiting for the slow EMA to
    /// drag the target all the way below the stale pre-emergency reference.
    func notifyEmergencyReleased() {
        optimizedLastSetRPM = lastAppliedRPM   // fan is wherever it physically is
    }

    private func calculateOptimizedRPM(cpuTemp: Double, cpuThermalLevel: Int,
                                       gpuTemp: Double, gpuThermalLevel: Int,
                                       packagePowerW: Double,
                                       isThrottling: Bool) -> Double {
        // Only go to max when pressure is Heavy or Trapping (severity ≥ 2).
        if isThrottling { return maxRPM }

        // ── Input smoothing (EMA) ────────────────────────────────────────────
        // Package power spikes heavily with Turbo Boost (e.g. 5W → 28W in one
        // 500ms sample). Smooth with α=0.12 (τ ≈ 3.9 s at 500ms sampling) so
        // brief bursts barely move the EMA.
        let alphaPower: Double = 0.12
        smoothedPowerW = smoothedPowerW == 0
            ? packagePowerW                                         // seed on first sample
            : smoothedPowerW + alphaPower * (packagePowerW - smoothedPowerW)

        // ── Per-sensor factors ───────────────────────────────────────────────
        // Temperature: 55°C → 0.0, 95°C → 1.0 (same envelope for CPU and GPU).
        let cpuTempFactor  = ((cpuTemp - 55.0) / 40.0).clamped(0, 1)
        let gpuTempFactor  = gpuTemp > 0 ? ((gpuTemp - 55.0) / 40.0).clamped(0, 1) : 0

        // Thermal level (Apple's 0–100 scale).
        let cpuLevelFactor = (Double(cpuThermalLevel) / 100.0).clamped(0, 1)
        let gpuLevelFactor = (Double(gpuThermalLevel) / 100.0).clamped(0, 1)

        // Power: 0W → 0.0, 28W (TDP) → 1.0 — leading indicator, already smoothed.
        let powerFactor = (smoothedPowerW / 28.0).clamped(0, 1)

        // Combine: temperature is the authoritative signal; power is an early
        // warning. Use weighted average so a single spiking factor doesn't
        // dominate the way a bare max() would.
        let rawF = max(cpuTempFactor, gpuTempFactor, cpuLevelFactor, gpuLevelFactor) * 0.70
                 + powerFactor * 0.30

        // ── Output smoothing (EMA) ───────────────────────────────────────────
        // Smooth the aggregated factor with α=0.08 (τ ≈ 5.9 s at 500ms sampling).
        // The fan only tracks sustained workloads, not momentary noise.
        let alphaF: Double = 0.08
        smoothedF = smoothedF == 0
            ? rawF
            : smoothedF + alphaF * (rawF - smoothedF)

        // ── Fan curve ────────────────────────────────────────────────────────
        // Quadratic: gentle at low-f, escalates in the upper half.
        // f=0.25 → 6%, f=0.50 → 25%, f=0.75 → 56%, f=1.0 → 100%
        let curve = smoothedF * smoothedF

        // Baseline: 30% above minimum — a noticeable head-start above Apple auto.
        let baseline = minRPM + (maxRPM - minRPM) * 0.30
        let target   = baseline + (maxRPM - baseline) * curve

        return target.clamped(minRPM, maxRPM)
    }

    // MARK: - Private helpers

    private func applyRPM(_ rpm: Double, completion: ((Bool) -> Void)? = nil) {
        let rawClamped = rpm.clamped(minRPM, maxRPM)

        // Slew-rate limiter: prevents instantaneous large RPM steps that stress
        // the fan motor controller. The limit matches Apple's observed auto ramp rate.
        let now      = Date()
        let elapsed  = max(0.05, now.timeIntervalSince(lastApplyTime))
        let maxDelta = Self.maxSlewRateRPMPerSec * elapsed
        let slewedRPM: Double
        if rawClamped > lastAppliedRPM {
            slewedRPM = min(rawClamped, lastAppliedRPM + maxDelta)
        } else {
            slewedRPM = max(rawClamped, lastAppliedRPM - maxDelta)
        }

        lastApplyTime   = now
        lastAppliedRPM  = slewedRPM

        fanLog.debug("applyRPM: target=\(rawClamped, privacy: .public) slewed=\(slewedRPM, privacy: .public) Δ=\(elapsed, privacy: .public)s")

        runHelper(args: ["set", String(format: "%.0f", slewedRPM)]) { [weak self] output in
            let ok = output.flatMap(Double.init) != nil
            DispatchQueue.main.async {
                if ok {
                    self?.isManual  = true
                    self?.targetRPM = slewedRPM
                }
                completion?(ok)
            }
        }
    }

    /// Bypass the slew-rate limiter and immediately command fans to absolute maximum.
    /// Only call this from the thermal emergency path (≥ emergencyTempThreshold).
    func setFanMaxEmergency() {
        let target = maxRPM
        fanLog.error("setFanMaxEmergency: commanding \(target, privacy: .public) RPM immediately")
        runHelper(args: ["set", String(format: "%.0f", target)]) { [weak self] output in
            guard let self else { return }
            let ok = output.flatMap(Double.init) != nil
            DispatchQueue.main.async {
                if ok {
                    self.isManual       = true
                    self.targetRPM      = target
                    // Sync slew-rate state so the next normal applyRPM call
                    // computes the correct delta from max rather than the old value.
                    self.lastAppliedRPM = target
                    self.lastApplyTime  = Date()
                }
            }
        }
    }

    private func runHelper(args: [String], completion: @escaping (String?) -> Void) {
        guard isAvailable else { completion(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments     = ["-n", Self.helperInstallPath] + args
            let stdout = Pipe()
            let stderr = Pipe()
            p.standardOutput = stdout
            p.standardError  = stderr
            stderr.fileHandleForReading.readabilityHandler = { _ in }
            do {
                try p.run()
                p.waitUntilExit()
                stderr.fileHandleForReading.readabilityHandler = nil
                let data   = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if p.terminationStatus != 0 {
                    fanLog.error("tc-fan-helper exited \(p.terminationStatus, privacy: .public) for args: \(args.joined(separator: " "), privacy: .public)")
                }
                completion(output)
            } catch {
                fanLog.error("tc-fan-helper launch failed: \(error.localizedDescription, privacy: .public)")
                completion(nil)
            }
        }
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double {
        Swift.max(lo, Swift.min(hi, self))
    }
}
