//
//  SMCFanController.swift
//  Thermal Control
//
//  Reads fan information from SMC via tc-fan-helper (read-only).
//  The only write performed is a one-time automatic release of any SMC manual
//  lock left behind by a previous crash, so macOS firmware immediately regains
//  full fan control.
//

import Foundation
import CryptoKit
import os.log

private let fanLog = Logger(subsystem: "com.thermalcontrol", category: "fan")

// MARK: - Controller

final class SMCFanController: ObservableObject {

    static let helperInstallPath = "/usr/local/bin/tc-fan-helper"

    static let absoluteMinRPM: Double = 1200
    static let absoluteMaxRPM: Double = 6200

    static var expectedHelperSHA256: String = ""

    @Published var isAvailable: Bool = false
    @Published var minRPM: Double = 2000
    @Published var maxRPM: Double = 6200
    @Published var fanCount: Int = 1

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

    /// Reads fan limits from SMC and releases any orphaned manual lock.
    func readState() {
        runHelper(args: ["get"]) { [weak self] output in
            guard let self, let output else { return }
            var manual = 0
            var currentRPM: Double = 0
            var minR: Double = 2000
            var maxR: Double = 6200
            var fans = 1
            for pair in output.components(separatedBy: " ") {
                let kv = pair.components(separatedBy: "=")
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "rpm":    currentRPM = Double(kv[1]) ?? 0
                case "min":    minR       = Double(kv[1]) ?? 2000
                case "max":    maxR       = Double(kv[1]) ?? 6200
                case "manual": manual     = Int(kv[1])    ?? 0
                case "fans":   fans       = Int(kv[1])    ?? 1
                default: break
                }
            }
            minR = minR.clamped(Self.absoluteMinRPM, Self.absoluteMaxRPM)
            maxR = maxR.clamped(minR, Self.absoluteMaxRPM)

            if manual == 1 {
                fanLog.warning("SMC manual override detected (RPM=\(currentRPM, privacy: .public)) — releasing orphaned lock so macOS firmware regains control")
                self.releaseManualLock()
            }

            DispatchQueue.main.async {
                self.minRPM   = minR
                self.maxRPM   = maxR
                self.fanCount = fans
            }
        }
    }

    /// Sends 'auto' to the helper to release an orphaned SMC manual lock.
    private func releaseManualLock(attempt: Int = 0) {
        runHelper(args: ["auto"]) { [weak self] output in
            let ok = output?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
            if ok {
                fanLog.info("Orphaned SMC manual lock released — macOS firmware now controls fans.")
            } else if attempt == 0 {
                fanLog.warning("releaseManualLock: helper did not return 'ok' — retrying once")
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    self?.releaseManualLock(attempt: 1)
                }
            } else {
                fanLog.error("Failed to release orphaned SMC lock after retry (output: \(output ?? "nil", privacy: .public))")
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
