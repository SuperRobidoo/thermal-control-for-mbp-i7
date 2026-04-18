//
//  PowerLimitRowView.swift
//  Thermal Control
//

import SwiftUI

struct PowerLimitRowView: View {
    var cpuPLimit: Double
    var gpuPLimitInt: Double
    var gpuPLimitExt: Double
    var prochotCount: Int

    var body: some View {
        HStack(spacing: 10) {
            StatCard(label: "CPU Plimit",  value: String(format: "%.2f%%", cpuPLimit),    isAlert: cpuPLimit > 0)
            StatCard(label: "GPU Plimit",  value: String(format: "%.2f%%", gpuPLimitInt),  isAlert: gpuPLimitInt > 0)
            StatCard(label: "GPU Ext",     value: String(format: "%.2f%%", gpuPLimitExt),  isAlert: gpuPLimitExt > 0)
            StatCard(label: "Prochots",    value: "\(prochotCount)",                        isAlert: prochotCount > 0,
                     icon: prochotCount > 0 ? "bolt.trianglebadge.exclamationmark.fill" : nil)
        }
    }
}

private struct StatCard: View {
    var label: String
    var value: String
    var isAlert: Bool
    var icon: String? = nil

    private var alertColor: Color { Color(red: 0.91, green: 0.25, blue: 0.15) }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(alertColor)
                }
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isAlert ? alertColor : .primary)
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            isAlert ? alertColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isAlert ? alertColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
    }
}

#Preview {
    VStack(spacing: 12) {
        PowerLimitRowView(cpuPLimit: 0, gpuPLimitInt: 0, gpuPLimitExt: 0, prochotCount: 0)
        PowerLimitRowView(cpuPLimit: 12.5, gpuPLimitInt: 0, gpuPLimitExt: 0, prochotCount: 2)
    }
    .padding()
    .frame(width: 520)
}
