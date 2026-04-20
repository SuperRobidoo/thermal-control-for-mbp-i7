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
    // cpu_power sampler fields
    var packagePowerW: Double
    var cpuFreqNominalPct: Double

    var body: some View {
        VStack(spacing: 8) {
            // Power-limit row (unchanged)
            HStack(spacing: 10) {
                StatCard(label: "CPU Plimit",  value: String(format: "%.2f%%", cpuPLimit),    isAlert: cpuPLimit > 0)
                StatCard(label: "GPU Plimit",  value: String(format: "%.2f%%", gpuPLimitInt),  isAlert: gpuPLimitInt > 0)
                StatCard(label: "GPU Ext",     value: String(format: "%.2f%%", gpuPLimitExt),  isAlert: gpuPLimitExt > 0)
                StatCard(label: "Prochots",    value: "\(prochotCount)",                        isAlert: prochotCount > 0,
                         icon: prochotCount > 0 ? "bolt.trianglebadge.exclamationmark.fill" : nil)
            }
            // Power & load row (cpu_power sampler)
            HStack(spacing: 10) {
                StatCard(
                    label:   "Pkg Power",
                    value:   String(format: "%.1f W", packagePowerW),
                    isAlert: packagePowerW > 25,  // approaching 28W TDP
                    icon:    packagePowerW > 25 ? "flame.fill" : nil
                )
                StatCard(
                    label:   "CPU Freq",
                    // < 95% = measurable frequency throttling; highlight in amber
                    value:   String(format: "%.1f%%", cpuFreqNominalPct),
                    isAlert: cpuFreqNominalPct > 0 && cpuFreqNominalPct < 95
                )
            }
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
        PowerLimitRowView(cpuPLimit: 0, gpuPLimitInt: 0, gpuPLimitExt: 0, prochotCount: 0,
                          packagePowerW: 8.5, cpuFreqNominalPct: 100)
        PowerLimitRowView(cpuPLimit: 12.5, gpuPLimitInt: 0, gpuPLimitExt: 0, prochotCount: 2,
                          packagePowerW: 27.3, cpuFreqNominalPct: 82)
    }
    .padding()
    .frame(width: 520)
}
