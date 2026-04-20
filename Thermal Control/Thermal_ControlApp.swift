//
//  Thermal_ControlApp.swift
//  Thermal Control
//

import SwiftUI
import UserNotifications
import os.log

private let appLog = Logger(subsystem: "com.thermalcontrol", category: "app")

// MARK: - App delegate (handles quit cleanup)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var monitor: ThermalMonitor?
    /// Retained to keep the SIGTERM DispatchSource alive for the process lifetime.
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSigtermHandler()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let fc = monitor?.fanController, fc.mode != .auto else { return }
        appLog.info("applicationWillTerminate: resetting SMC fan control to auto")
        // Synchronously reset SMC fan control before the process exits.
        // Hard 500 ms timeout — never block process teardown indefinitely.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments     = ["-n", SMCFanController.helperInstallPath, "auto"]
        p.standardOutput = Pipe()
        p.standardError  = Pipe()
        guard (try? p.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(0.5)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            appLog.warning("applicationWillTerminate: helper did not finish within timeout — terminating it")
            p.terminate()
        }
    }

    // MARK: - SIGTERM handler

    /// Installs a DispatchSource-based SIGTERM handler so the SMC is reset even
    /// when the process is terminated by launchctl, memory pressure, or the user
    /// via `kill` — paths that bypass applicationWillTerminate.
    private func installSigtermHandler() {
        signal(SIGTERM, SIG_IGN)  // suppress default handling; DispatchSource takes over
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            appLog.info("SIGTERM received — resetting SMC fan control before exit")
            if let fc = self?.monitor?.fanController, fc.mode != .auto {
                // Run the helper synchronously, same as applicationWillTerminate.
                // setAuto() is async (dispatches to a background queue) and cannot
                // be relied upon before exit(0) — use a direct Process with timeout.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                p.arguments     = ["-n", SMCFanController.helperInstallPath, "auto"]
                p.standardOutput = Pipe()
                p.standardError  = Pipe()
                guard (try? p.run()) != nil else { exit(0) }
                let deadline = Date().addingTimeInterval(0.5)
                while p.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if p.isRunning {
                    appLog.warning("SIGTERM: helper did not finish within timeout — terminating it")
                    p.terminate()
                }
            }
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }
}

@main
struct Thermal_ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = ThermalMonitor()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Main dashboard window
        WindowGroup(id: "dashboard") {
            MainDashboardView()
                .environmentObject(monitor)
                .onAppear {
                    appDelegate.monitor = monitor   // give delegate access for quit cleanup
                    monitor.start()
                    NotificationManager.shared.requestPermission()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        // Menu bar widget
        MenuBarExtra {
            MenuBarPopoverView(openDashboard: {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            })
            .environmentObject(monitor)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        if monitor.isRunning {
            HStack(spacing: 2) {
                Image(systemName: "thermometer.medium")
                Text(String(format: "%.0f°", monitor.currentTemperature))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
        } else {
            Image(systemName: "thermometer.medium")
        }
    }
}
