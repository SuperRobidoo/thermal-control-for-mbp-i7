//
//  PowerMetricsService.swift
//  Thermal Control
//

import Foundation
import os.log

private let serviceLog = Logger(subsystem: "com.thermalcontrol", category: "powermetrics")

@available(*, deprecated, message: "Use serviceLog instead")
private func tcLog(_ msg: String, file: String = #file, line: Int = #line) {
    let f = (file as NSString).lastPathComponent
    serviceLog.debug("\(f, privacy: .public):\(line, privacy: .public) \(msg, privacy: .public)")
}

struct RawThermalSample {
    let cpuTemperature: Double
    let thermalPressure: String
    let cpuThermalLevel: Int
    let gpuThermalLevel: Int
    let ioThermalLevel: Int
    let fanRPM: Int
    let gpuTemperature: Double
    let cpuPLimit: Double
    let gpuPLimitInt: Double
    let gpuPLimitExt: Double
    let prochotCount: Int
    // cpu_power sampler fields (leading-indicator data)
    let packagePowerW: Double      // Intel energy-model package power (CPU+GT+SA)
    let cpuFreqNominalPct: Double  // Average frequency as % of nominal (< 100 = throttled)
    let coresActivePct: Double     // % of logical cores active
    let gpuActivePct: Double       // Integrated GPU busy %
}

// MARK: - Sensor validation

struct SensorValidationError: Error {
    enum Fault: CustomStringConvertible {
        case belowPlausible, abovePhysicalMax
        var description: String {
            switch self {
            case .belowPlausible:   return "below plausible range"
            case .abovePhysicalMax: return "above physical maximum"
            }
        }
    }
    let field: String
    let value: Double
    let fault: Fault
    var localizedDescription: String { "\(field)=\(value): \(fault)" }
}

final class PowerMetricsService {
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var outputBuffer = ""
    private let queue = DispatchQueue(label: "com.thermalcontrol.powermetrics", qos: .utility)
    var onSample: ((RawThermalSample) -> Void)?
    var onError: ((String) -> Void)?
    var onPermissionRequired: (() -> Void)?

    private(set) var sampleIntervalMs: Int = 2000

    // Maximum bytes retained in the rolling output buffer before forced truncation.
    private static let maxBufferBytes = 256 * 1024  // 256 KB

    // Consecutive parse/validation failure counters.
    private var consecutiveParseFailures = 0
    private var consecutiveInvalidSamples = 0
    private static let maxConsecutiveFailures = 10

    /// True when the powermetrics subprocess is alive.
    var isProcessRunning: Bool { process?.isRunning == true }

    func start() {
        serviceLog.info("start() called")
        queue.async { [weak self] in
            self?.checkPermissionThenLaunch()
        }
    }

    /// Call this after the sudoers entry has been written — skips the permission check.
    func startAfterPrivilegesGranted() {
        serviceLog.info("startAfterPrivilegesGranted() called — bypassing permission check")
        queue.async { [weak self] in
            self?.launchProcess()
        }
    }

    /// Restart with a new sampling interval (e.g. 500ms for smart fan mode).
    func restartWithInterval(_ ms: Int) {
        guard ms != sampleIntervalMs else { return }
        serviceLog.info("restartWithInterval(): changing interval \(self.sampleIntervalMs, privacy: .public)ms → \(ms, privacy: .public)ms")
        sampleIntervalMs = ms
        stop()
        startAfterPrivilegesGranted()
    }

    func stop() {
        serviceLog.info("stop() called")
        process?.terminate()
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        outputBuffer = ""
        consecutiveParseFailures  = 0
        consecutiveInvalidSamples = 0
    }

    // MARK: - Permission check

    /// Quick non-interactive sudo test. Returns true if sudo works without a password.
    static func canRunWithoutPassword() -> Bool {
        // Fast path: if our sudoers entry was already written, permission is granted.
        if FileManager.default.fileExists(atPath: "/etc/sudoers.d/thermalcontrol") {
            serviceLog.debug("canRunWithoutPassword(): sudoers entry exists — skipping live test")
            return true
        }
        serviceLog.debug("canRunWithoutPassword(): running sudo -n /usr/bin/true …")
        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        test.arguments = ["-n", "/usr/bin/true"]
        test.standardOutput = Pipe()
        test.standardError = Pipe()
        try? test.run()
        test.waitUntilExit()
        let ok = test.terminationStatus == 0
        serviceLog.debug("canRunWithoutPassword(): result = \(ok, privacy: .public) (exit \(test.terminationStatus, privacy: .public))")
        return ok
    }

    private func checkPermissionThenLaunch() {
        serviceLog.debug("checkPermissionThenLaunch(): testing sudo permission …")
        if Self.canRunWithoutPassword() {
            serviceLog.debug("checkPermissionThenLaunch(): permission OK — launching process")
            launchProcess()
        } else {
            serviceLog.warning("checkPermissionThenLaunch(): PERMISSION DENIED — firing onPermissionRequired")
            DispatchQueue.main.async { self.onPermissionRequired?() }
        }
    }

    // MARK: - Launch

    private func launchProcess() {
        serviceLog.info("launchProcess(): setting up Process for /usr/bin/sudo -n /usr/bin/powermetrics …")
        let p = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // Omit -n (sample count) so powermetrics runs indefinitely.
        // "-n 0" is ambiguous across macOS versions and caused immediate exit.
        p.arguments = ["-n", "/usr/bin/powermetrics", "--samplers", "smc,cpu_power", "-i", "\(sampleIntervalMs)"]
        p.standardOutput = outPipe
        p.standardError  = errPipe

        serviceLog.info("launchProcess(): args = \(p.arguments!.joined(separator: " "), privacy: .public)")

        // Capture stdout
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                serviceLog.debug("launchProcess(): stdout EOF — process likely exited")
                return
            }
            if let chunk = String(data: data, encoding: .utf8) {
                self?.processChunk(chunk)
            } else {
                serviceLog.warning("launchProcess(): could not decode stdout chunk as UTF-8")
            }
        }

        // Capture stderr so it surfaces in Console.app and doesn't block the pipe buffer
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let msg = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
            serviceLog.error("powermetrics stderr: \(msg.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
        }

        p.terminationHandler = { [weak self] proc in
            serviceLog.info("launchProcess(): process terminated status=\(proc.terminationStatus, privacy: .public) reason=\(proc.terminationReason.rawValue, privacy: .public)")
            if proc.terminationStatus != 0 {
                DispatchQueue.main.async {
                    self?.onError?("powermetrics exited with status \(proc.terminationStatus)")
                }
            }
        }

        do {
            try p.run()
            self.process    = p
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe
            serviceLog.info("launchProcess(): process running PID \(p.processIdentifier, privacy: .public)")
        } catch {
            serviceLog.error("launchProcess(): FAILED to launch — \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async {
                self.onError?("Failed to start powermetrics: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Parsing

    // powermetrics separates each sample with a "*** Sampled system activity" header line.
    // We only parse once we have at least one complete block (i.e. two header lines).
    private func processChunk(_ chunk: String) {
        // Guard against unbounded buffer growth (e.g. powermetrics producing oversized output
        // during system stress or with additional samplers active).
        if outputBuffer.utf8.count + chunk.utf8.count > Self.maxBufferBytes {
            let separator = "*** Sampled system activity"
            if let lastSep = outputBuffer.range(of: separator, options: .backwards) {
                let truncated = String(outputBuffer[lastSep.lowerBound...])
                // The parser requires at least two separators to produce one complete block.
                // If only one separator remains after truncation, the parser would stall
                // until the next separator arrives. Clear the buffer instead and accept
                // the loss of this partial block.
                let sepCount = truncated.components(separatedBy: separator).count - 1
                if sepCount >= 2 {
                    outputBuffer = truncated
                    serviceLog.warning("outputBuffer exceeded \(Self.maxBufferBytes, privacy: .public) bytes — truncated to last two separators")
                } else {
                    outputBuffer = ""
                    serviceLog.warning("outputBuffer exceeded limit; too few separators after truncation — buffer cleared")
                }
            } else {
                outputBuffer = ""
                serviceLog.warning("outputBuffer exceeded limit and no separator found — buffer cleared")
            }
        }

        outputBuffer += chunk

        // Split on the powermetrics block separator
        let separator = "*** Sampled system activity"
        let blocks = outputBuffer.components(separatedBy: separator)

        // blocks[0] is whatever came before the first header (often empty or a preamble).
        // A complete sample block is the content between two consecutive headers.
        // We need at least 2 separators to have one complete block.
        guard blocks.count >= 3 else {
            return
        }

        // Use the second-to-last complete block (most recent finished sample)
        let blockContent = separator + blocks[blocks.count - 2]

        let cpuTempRx      = /CPU die temperature:\s+(\d+\.?\d*)\s+C/
        let pressureRx     = /Thermal pressure:\s+(\w+)/
        let cpuLevelRx     = /CPU Thermal level:\s+(\d+)/
        let gpuLevelRx     = /GPU Thermal level:\s+(\d+)/
        let ioLevelRx      = /IO Thermal level:\s+(\d+)/
        let fanRx          = /Fan:\s+(\d+)\s+rpm/
        let gpuTempRx      = /GPU die temperature:\s+(\d+\.?\d*)\s+C/
        let cpuPlimitRx    = /CPU Plimit:\s+(\d+\.?\d*)/
        let gpuPlimitIntRx = /GPU Plimit \(Int\):\s+(\d+\.?\d*)/
        let gpuPlimitExtRx = /GPU2 Plimit \(Ext1\):\s+(\d+\.?\d*)/
        let prochotRx      = /Number of prochots:\s+(\d+)/
        // cpu_power sampler fields
        let pkgPowerRx     = /Intel energy model derived package power \(CPUs\+GT\+SA\):\s+(\d+\.?\d*)\s*W/
        let cpuFreqRx      = /System Average frequency as fraction of nominal:\s+(\d+\.?\d*)%/
        let coresActiveRx  = /Cores Active:\s+(\d+\.?\d*)%/
        let gpuActiveRx    = /GPU Active:\s+(\d+\.?\d*)%/

        var cpuTemp: Double?
        var pressure: String?
        var cpuLevel: Int?
        var gpuLevel: Int?
        var ioLevel: Int?
        var fanRPM: Int?
        var gpuTemp: Double?
        var cpuPLimit: Double?
        var gpuPLimitInt: Double?
        var gpuPLimitExt: Double?
        var prochotCount: Int?
        var packagePowerW: Double?
        var cpuFreqNominalPct: Double?
        var coresActivePct: Double?
        var gpuActivePct: Double?

        for line in blockContent.components(separatedBy: "\n") {
            if let m = try? cpuTempRx.firstMatch(in: line)      { cpuTemp           = Double(m.output.1) }
            if let m = try? pressureRx.firstMatch(in: line)     { pressure          = String(m.output.1) }
            if let m = try? cpuLevelRx.firstMatch(in: line)     { cpuLevel          = Int(m.output.1) }
            if let m = try? gpuLevelRx.firstMatch(in: line)     { gpuLevel          = Int(m.output.1) }
            if let m = try? ioLevelRx.firstMatch(in: line)      { ioLevel           = Int(m.output.1) }
            if let m = try? fanRx.firstMatch(in: line)          { fanRPM            = Int(m.output.1) }
            if let m = try? gpuTempRx.firstMatch(in: line)      { gpuTemp           = Double(m.output.1) }
            if let m = try? cpuPlimitRx.firstMatch(in: line)    { cpuPLimit         = Double(m.output.1) }
            if let m = try? gpuPlimitIntRx.firstMatch(in: line) { gpuPLimitInt      = Double(m.output.1) }
            if let m = try? gpuPlimitExtRx.firstMatch(in: line) { gpuPLimitExt      = Double(m.output.1) }
            if let m = try? prochotRx.firstMatch(in: line)      { prochotCount      = Int(m.output.1) }
            if let m = try? pkgPowerRx.firstMatch(in: line)     { packagePowerW     = Double(m.output.1) }
            if let m = try? cpuFreqRx.firstMatch(in: line)      { cpuFreqNominalPct = Double(m.output.1) }
            if let m = try? coresActiveRx.firstMatch(in: line)  { coresActivePct    = Double(m.output.1) }
            if let m = try? gpuActiveRx.firstMatch(in: line)    { gpuActivePct      = Double(m.output.1) }
        }

        guard let t = cpuTemp else {
            consecutiveParseFailures += 1
            serviceLog.warning("processChunk(): cpuTemp not found in block (miss \(self.consecutiveParseFailures, privacy: .public)/\(Self.maxConsecutiveFailures, privacy: .public))")
            if consecutiveParseFailures >= Self.maxConsecutiveFailures {
                let msg = "powermetrics parsing failed \(consecutiveParseFailures) consecutive times"
                serviceLog.error("\(msg, privacy: .public)")
                DispatchQueue.main.async { self.onError?(msg) }
            }
            // Retain the last partial block to preserve buffered data
            if let lastSep = outputBuffer.range(of: separator, options: .backwards) {
                outputBuffer = String(outputBuffer[lastSep.lowerBound...])
            }
            return
        }
        consecutiveParseFailures = 0

        // ── Sensor plausibility validation ────────────────────────────────────
        // Reject readings that are physically impossible for the i7-7567U.
        // 0°C indicates a failed/stale SMC read; > 115°C is above sensor range.
        do {
            try validateSample(cpuTemp: t, gpuTemp: gpuTemp ?? 0, fanRPM: fanRPM ?? 0)
            consecutiveInvalidSamples = 0
        } catch let e as SensorValidationError {
            consecutiveInvalidSamples += 1
            serviceLog.error("Sensor validation FAILED: \(e.localizedDescription, privacy: .public) (consecutive=\(self.consecutiveInvalidSamples, privacy: .public))")
            if consecutiveInvalidSamples >= Self.maxConsecutiveFailures {
                let msg = "Sensor validation failed \(consecutiveInvalidSamples) consecutive times — last: \(e.localizedDescription)"
                DispatchQueue.main.async { self.onError?(msg) }
            }
            if let lastSep = outputBuffer.range(of: separator, options: .backwards) {
                outputBuffer = String(outputBuffer[lastSep.lowerBound...])
            }
            return
        } catch {
            // Unexpected error type — log and drop the sample
            serviceLog.error("Unexpected validation error: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Thermal pressure is not in --samplers smc output; infer from cpuThermalLevel.
        let inferredPressure: String
        if let p = pressure {
            inferredPressure = p
        } else {
            let level = cpuLevel ?? 0
            switch level {
            case 0..<33:  inferredPressure = "Nominal"
            case 33..<66: inferredPressure = "Moderate"
            case 66..<90: inferredPressure = "Heavy"
            default:      inferredPressure = "Trapping"
            }
        }

        let sample = RawThermalSample(
            cpuTemperature:   t,
            thermalPressure:  inferredPressure,
            cpuThermalLevel:  cpuLevel ?? 0,
            gpuThermalLevel:  gpuLevel ?? 0,
            ioThermalLevel:   ioLevel ?? 0,
            fanRPM:           fanRPM ?? 0,
            gpuTemperature:   gpuTemp ?? 0,
            cpuPLimit:        cpuPLimit ?? 0,
            gpuPLimitInt:     gpuPLimitInt ?? 0,
            gpuPLimitExt:     gpuPLimitExt ?? 0,
            prochotCount:     prochotCount ?? 0,
            packagePowerW:    packagePowerW ?? 0,
            cpuFreqNominalPct: cpuFreqNominalPct ?? 0,
            coresActivePct:   coresActivePct ?? 0,
            gpuActivePct:     gpuActivePct ?? 0
        )
        serviceLog.debug("sample emitted: cpu=\(t, privacy: .public)°C pkg=\(packagePowerW ?? 0, privacy: .public)W freq=\(cpuFreqNominalPct ?? 0, privacy: .public)% fan=\(fanRPM ?? 0, privacy: .public)rpm")
        DispatchQueue.main.async { self.onSample?(sample) }

        // Keep only the last partial block in the buffer to bound memory usage
        if let lastSep = outputBuffer.range(of: separator, options: .backwards) {
            outputBuffer = String(outputBuffer[lastSep.lowerBound...])
        }
    }

    // MARK: - Sensor validation

    /// Validates that parsed sensor values fall within physically plausible ranges
    /// for the MacBook Pro 2017 (i7-7567U / Radeon Pro 560).
    /// - Throws: `SensorValidationError` for the first out-of-range field.
    /// NOTE: Zero RPM is intentionally NOT rejected here. A stall while the CPU
    /// is warm is a valid (and safety-critical) reading that must reach
    /// ThermalMonitor.checkFanStall(). Blocking it here would blind emergency
    /// thermal protection during the exact scenario it is designed for.
    private func validateSample(cpuTemp: Double, gpuTemp: Double, fanRPM: Int) throws {
        // Ambient lower bound: a CPU reading below 10°C cannot occur in any real Mac
        // use case; it indicates a failed/stale SMC register read.
        if cpuTemp < 10.0 {
            throw SensorValidationError(field: "cpuTemp", value: cpuTemp, fault: .belowPlausible)
        }
        // i7-7567U Tj,max = 100°C; sensors above 115°C are outside the hardware range.
        if cpuTemp > 115.0 {
            throw SensorValidationError(field: "cpuTemp", value: cpuTemp, fault: .abovePhysicalMax)
        }
        // GPU temp: only validate when the sensor returned a non-zero value.
        if gpuTemp > 0 {
            if gpuTemp < 10.0 {
                throw SensorValidationError(field: "gpuTemp", value: gpuTemp, fault: .belowPlausible)
            }
            if gpuTemp > 115.0 {
                throw SensorValidationError(field: "gpuTemp", value: gpuTemp, fault: .abovePhysicalMax)
            }
        }
    }
}
