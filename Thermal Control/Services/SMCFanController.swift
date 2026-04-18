//
//  SMCFanController.swift
//  Thermal Control
//
//  Manages manual fan speed control via the bundled tc-fan-helper binary.
//  Write operations require root — the helper is invoked with sudo -n,
//  relying on the NOPASSWD sudoers entry written during privilege setup.
//

import Foundation

final class SMCFanController: ObservableObject {

    static let helperInstallPath = "/usr/local/bin/tc-fan-helper"

    @Published var isAvailable: Bool = false
    @Published var isManual: Bool = false
    @Published var targetRPM: Double = 0
    @Published var minRPM: Double = 2000
    @Published var maxRPM: Double = 6200
    @Published var fanCount: Int = 2

    init() {
        refreshAvailability()
    }

    func refreshAvailability() {
        let fm = FileManager.default
        isAvailable = fm.fileExists(atPath: Self.helperInstallPath)
                   && fm.isExecutableFile(atPath: Self.helperInstallPath)
        if isAvailable { readState() }
    }

    /// Read current fan mode, target, min, and max from SMC.
    func readState() {
        runHelper(args: ["get"]) { [weak self] output in
            guard let self, let output else { return }
            // "rpm=2001 min=2000 max=5700 manual=0 target=0 fans=2"
            var manual = 0
            var target: Double = 0
            var minR: Double = 2000
            var maxR: Double = 6200
            var fans = 2
            for pair in output.components(separatedBy: " ") {
                let kv = pair.components(separatedBy: "=")
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "min":    minR   = Double(kv[1]) ?? 2000
                case "max":    maxR   = Double(kv[1]) ?? 6200
                case "manual": manual = Int(kv[1]) ?? 0
                case "target": target = Double(kv[1]) ?? 0
                case "fans":   fans   = Int(kv[1]) ?? 2
                default: break
                }
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

    /// Switch fans back to automatic SMC control.
    func setAuto(completion: ((Bool) -> Void)? = nil) {
        runHelper(args: ["auto"]) { [weak self] output in
            let ok = output?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
            DispatchQueue.main.async {
                if ok { self?.isManual = false }
                completion?(ok)
            }
        }
    }

    /// Set a manual target RPM for all fans.
    func setManual(rpm: Double, completion: ((Bool) -> Void)? = nil) {
        let clamped = min(maxRPM, max(minRPM, rpm))
        runHelper(args: ["set", String(format: "%.0f", clamped)]) { [weak self] output in
            let ok = output.flatMap(Double.init) != nil
            DispatchQueue.main.async {
                if ok {
                    self?.isManual   = true
                    self?.targetRPM  = clamped
                }
                completion?(ok)
            }
        }
    }

    // MARK: - Private

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
            // drain stderr so it never blocks
            stderr.fileHandleForReading.readabilityHandler = { _ in }
            do {
                try p.run()
                p.waitUntilExit()
                stderr.fileHandleForReading.readabilityHandler = nil
                let data   = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                completion(output)
            } catch {
                completion(nil)
            }
        }
    }
}
