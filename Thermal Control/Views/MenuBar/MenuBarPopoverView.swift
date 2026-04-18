//
//  MenuBarPopoverView.swift
//  Thermal Control
//

import SwiftUI

struct MenuBarPopoverView: View {
    @EnvironmentObject private var monitor: ThermalMonitor

    // Callback to open the main window
    var openDashboard: () -> Void = {}

    private var tempText: String {
        monitor.isRunning ? String(format: "%.0f°C", monitor.currentTemperature) : "--°C"
    }

    private var pressureColor: Color {
        switch monitor.currentPressure {
        case .nominal: return .green
        case .moderate: return .yellow
        case .heavy: return .orange
        case .trapping: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Temperature row
            HStack {
                Image(systemName: "thermometer.medium")
                    .font(.title2)
                    .foregroundStyle(pressureColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tempText)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(pressureColor)
                    Text("CPU Temperature")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Throttle status
            ThrottlingStatusView(pressure: monitor.currentPressure)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Open Dashboard button
            Button(action: openDashboard) {
                Label("Open Dashboard", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 220)
    }
}

#Preview {
    MenuBarPopoverView()
        .environmentObject(ThermalMonitor())
}
