//
//  Thermal_ControlApp.swift
//  Thermal Control
//

import SwiftUI
import UserNotifications

@main
struct Thermal_ControlApp: App {
    @StateObject private var monitor = ThermalMonitor()

    var body: some Scene {
        // Main dashboard window
        WindowGroup {
            MainDashboardView()
                .environmentObject(monitor)
                .onAppear {
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
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
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
