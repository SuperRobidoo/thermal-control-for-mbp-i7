//
//  PowerMetricsService.swift
//  Thermal Control
//

import Foundation

// Lightweight tagged logger — visible in Xcode console
private func tcLog(_ msg: String, file: String = #file, line: Int = #line) {
    let f = (file as NSString).lastPathComponent
    print("[ThermalControl:\(f):\(line)] \(msg)")
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

    func start() {
        tcLog("start() called")
        queue.async { [weak self] in
            self?.checkPermissionThenLaunch()
        }
    }

    /// Call this after the sudoers entry has been written — skips the permission check.
    func startAfterPrivilegesGranted() {
        tcLog("startAfterPrivilegesGranted() called — bypassing permission check")
        queue.async { [weak self] in
            self?.launchProcess()
        }
    }

    func stop() {
        tcLog("stop() called")
        process?.terminate()
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        outputBuffer = ""
    }

    // MARK: - Permission check

    /// Quick non-interactive sudo test. Returns true if sudo works without a password.
    static func canRunWithoutPassword() -> Bool {
        tcLog("canRunWithoutPassword(): running sudo -n /usr/bin/true …")
        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        test.arguments = ["-n", "/usr/bin/true"]
        test.standardOutput = Pipe()
        test.standardError = Pipe()
        try? test.run()
        test.waitUntilExit()
        let ok = test.terminationStatus == 0
        tcLog("canRunWithoutPassword(): result = \(ok) (exit \(test.terminationStatus))")
        return ok
    }

    private func checkPermissionThenLaunch() {
        tcLog("checkPermissionThenLaunch(): testing sudo permission …")
        if Self.canRunWithoutPassword() {
            tcLog("checkPermissionThenLaunch(): permission OK — launching process")
            launchProcess()
        } else {
            tcLog("checkPermissionThenLaunch(): PERMISSION DENIED — firing onPermissionRequired")
            DispatchQueue.main.async { self.onPermissionRequired?() }
        }
    }

    // MARK: - Launch

    private func launchProcess() {
        tcLog("launchProcess(): setting up Process for /usr/bin/sudo -n /usr/bin/powermetrics …")
        let p = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // Omit -n (sample count) so powermetrics runs indefinitely.
        // "-n 0" is ambiguous across macOS versions and caused immediate exit.
        p.arguments = ["-n", "/usr/bin/powermetrics", "--samplers", "smc", "-i", "2000"]
        p.standardOutput = outPipe
        p.standardError  = errPipe

        tcLog("launchProcess(): args = \(p.arguments!.joined(separator: " "))")

        // Capture stdout
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                tcLog("launchProcess(): stdout EOF — process likely exited")
                return
            }
            tcLog("launchProcess(): stdout chunk \(data.count) bytes")
            if let chunk = String(data: data, encoding: .utf8) {
                self?.processChunk(chunk)
            } else {
                tcLog("launchProcess(): WARNING — could not decode stdout chunk as UTF-8")
            }
        }

        // Capture stderr so it surfaces in Xcode console and doesn't block the pipe buffer
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let msg = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
            tcLog("launchProcess(): STDERR from powermetrics → \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        p.terminationHandler = { proc in
            tcLog("launchProcess(): process terminated with status \(proc.terminationStatus) reason \(proc.terminationReason.rawValue)")
            if proc.terminationStatus != 0 {
                DispatchQueue.main.async {
                    self.onError?("powermetrics exited with status \(proc.terminationStatus) — check Xcode console for stderr")
                }
            }
        }

        do {
            try p.run()
            self.process  = p
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe
            tcLog("launchProcess(): process running PID \(p.processIdentifier)")
        } catch {
            tcLog("launchProcess(): FAILED to launch — \(error)")
            DispatchQueue.main.async {
                self.onError?("Failed to start powermetrics: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Parsing

    // powermetrics separates each sample with a "*** Sampled system activity" header line.
    // We only parse once we have at least one complete block (i.e. two header lines).
    private func processChunk(_ chunk: String) {
        outputBuffer += chunk
        tcLog("processChunk(): buffer now \(outputBuffer.count) chars")

        // Log first chunk raw so we can see exactly what powermetrics is sending
        if outputBuffer.count == chunk.count {
            tcLog("processChunk(): FIRST CHUNK RAW →\n\(chunk.prefix(500))")
        }

        // Split on the powermetrics block separator
        let separator = "*** Sampled system activity"
        let blocks = outputBuffer.components(separatedBy: separator)

        // blocks[0] is whatever came before the first header (often empty or a preamble).
        // A complete sample block is the content between two consecutive headers.
        // We need at least 2 separators to have one complete block.
        guard blocks.count >= 3 else {
            tcLog("processChunk(): only \(blocks.count) block(s) so far — waiting for complete sample")
            return
        }

        // Use the second-to-last complete block (most recent finished sample)
        let blockContent = separator + blocks[blocks.count - 2]
        tcLog("processChunk(): parsing block (\(blockContent.count) chars)")

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

        for line in blockContent.components(separatedBy: "\n") {
            if let m = try? cpuTempRx.firstMatch(in: line)      { cpuTemp      = Double(m.output.1) }
            if let m = try? pressureRx.firstMatch(in: line)     { pressure     = String(m.output.1) }
            if let m = try? cpuLevelRx.firstMatch(in: line)     { cpuLevel     = Int(m.output.1) }
            if let m = try? gpuLevelRx.firstMatch(in: line)     { gpuLevel     = Int(m.output.1) }
            if let m = try? ioLevelRx.firstMatch(in: line)      { ioLevel      = Int(m.output.1) }
            if let m = try? fanRx.firstMatch(in: line)          { fanRPM       = Int(m.output.1) }
            if let m = try? gpuTempRx.firstMatch(in: line)      { gpuTemp      = Double(m.output.1) }
            if let m = try? cpuPlimitRx.firstMatch(in: line)    { cpuPLimit    = Double(m.output.1) }
            if let m = try? gpuPlimitIntRx.firstMatch(in: line) { gpuPLimitInt = Double(m.output.1) }
            if let m = try? gpuPlimitExtRx.firstMatch(in: line) { gpuPLimitExt = Double(m.output.1) }
            if let m = try? prochotRx.firstMatch(in: line)      { prochotCount = Int(m.output.1) }
        }

        tcLog("processChunk(): parsed — cpuTemp=\(cpuTemp.map{"\($0)"} ?? "nil") pressure=\(pressure ?? "nil") cpuLevel=\(cpuLevel.map{"\($0)"} ?? "nil") fan=\(fanRPM.map{"\($0)"} ?? "nil")")

        guard let t = cpuTemp else {
            tcLog("processChunk(): guard failed — cpuTemp still nil in block")
            tcLog("processChunk(): block content →\n\(blockContent.prefix(800))")
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
            tcLog("processChunk(): pressure inferred from cpuLevel \(level) → \(inferredPressure)")
        }

        let sample = RawThermalSample(
            cpuTemperature: t,
            thermalPressure: inferredPressure,
            cpuThermalLevel: cpuLevel ?? 0,
            gpuThermalLevel: gpuLevel ?? 0,
            ioThermalLevel: ioLevel ?? 0,
            fanRPM: fanRPM ?? 0,
            gpuTemperature: gpuTemp ?? 0,
            cpuPLimit: cpuPLimit ?? 0,
            gpuPLimitInt: gpuPLimitInt ?? 0,
            gpuPLimitExt: gpuPLimitExt ?? 0,
            prochotCount: prochotCount ?? 0
        )
        tcLog("processChunk(): ✅ sample emitted — cpu=\(t)°C pressure=\(inferredPressure) fan=\(fanRPM ?? 0)rpm")
        DispatchQueue.main.async { self.onSample?(sample) }

        // Keep only the last partial block in the buffer to bound memory usage
        if let lastSep = outputBuffer.range(of: separator, options: .backwards) {
            outputBuffer = String(outputBuffer[lastSep.lowerBound...])
            tcLog("processChunk(): buffer trimmed, now \(outputBuffer.count) chars")
        }
    }
}
