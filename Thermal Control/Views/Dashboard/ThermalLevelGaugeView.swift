//
//  ThermalLevelGaugeView.swift
//  Thermal Control
//

import SwiftUI

struct ThermalLevelGaugeView: View {
    var label: String
    var value: Int // 0–100
    var icon: String

    private var fraction: Double { Double(value.clamped(to: 0...100)) / 100.0 }

    private var statusText: String {
        switch value {
        case ..<33: return "Normal"
        case 33..<66: return "Moderate"
        case 66..<90: return "High"
        default:     return "Critical"
        }
    }

    // Coral accent that deepens at high values
    private var barColor: Color {
        switch value {
        case ..<66: return Color(red: 0.91, green: 0.32, blue: 0.22)
        default:    return Color(red: 0.78, green: 0.12, blue: 0.08)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── Header ──
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
            }

            // ── Large value ──
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(value)")
                    .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(barColor)
                    .animation(.spring(response: 0.4), value: value)
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            // ── Pill progress bar ──
            GeometryReader { geo in
                let fillW = max(12.0, geo.size.width * fraction)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.1))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [barColor.opacity(0.7), barColor],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: fillW)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: fraction)
                }
                .frame(height: 10)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 10)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, x: 0, y: 2)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}

#Preview {
    HStack(spacing: 10) {
        ThermalLevelGaugeView(label: "CPU Thermal", value: 96, icon: "cpu")
        ThermalLevelGaugeView(label: "GPU Thermal", value: 29, icon: "gpu")
        ThermalLevelGaugeView(label: "IO Thermal",  value: 29, icon: "square.3.layers.3d")
    }
    .padding()
    .frame(width: 580)
}
