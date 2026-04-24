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
        appLog.info("applicationWillTerminate")
    }

    // MARK: - SIGTERM handler

    /// Installs a DispatchSource-based SIGTERM handler for clean shutdown.
    private func installSigtermHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            appLog.info("SIGTERM received — exiting")
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
