//
//  TemperatureGaugeView.swift
//  Thermal Control
//

import SwiftUI

struct TemperatureGaugeView: View {
    var temperature: Double
    var minTemp: Double = 0
    var maxTemp: Double = 120
    var title: String = "Temperature"
    var icon: String = "thermometer.medium"

    private var fraction: Double {
        ((temperature - minTemp) / (maxTemp - minTemp)).clamped(to: 0...1)
    }

    private var statusLabel: String {
        switch temperature {
        case ..<50:  return "Cool"
        case 50..<70: return "Normal"
        case 70..<85: return "Warm"
        case 85..<100: return "Hot"
        default:     return "Critical"
        }
    }

    private var tempColor: Color {
        switch temperature {
        case ..<70:  return Color(red: 0.18, green: 0.72, blue: 0.38)
        case 70..<85: return Color(red: 1.0, green: 0.55, blue: 0.0)
        default:     return Color(red: 0.91, green: 0.25, blue: 0.15)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── Header ──
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            // ── Tick-mark gauge ──
            TickGauge(fraction: fraction, maxTemp: Int(maxTemp))
                .aspectRatio(2.1, contentMode: .fit)
                .frame(maxWidth: .infinity)

            // ── Reading ──
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(temperature > 0 ? String(format: "%.1f", temperature) : "–")
                        .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tempColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("°C")
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if temperature > 0 {
                    Text(statusLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, x: 0, y: 2)
    }
}

// MARK: - Tick-mark semicircle gauge

private struct TickGauge: View {
    var fraction: Double
    var maxTemp: Int
    @State private var animated: Double = 0

    var body: some View {
        Canvas { ctx, size in
            let ticks = 36
            let cx    = size.width / 2
            let cy    = size.height * 0.92
            let outerR = min(size.width * 0.47, size.height * 0.92)
            let activeInner = outerR - 22.0
            let inactiveInner = outerR - 13.0

            for i in 0..<ticks {
                let t = Double(i) / Double(ticks - 1)
                let angleDeg = 180.0 - t * 180.0
                let rad = angleDeg * .pi / 180.0
                let cosA = CGFloat(cos(rad))
                let sinA = CGFloat(sin(rad))

                let isActive = t <= animated
                let innerR: Double = isActive ? activeInner : inactiveInner
                let outer = CGPoint(x: cx + outerR * cosA, y: cy - outerR * sinA)
                let inner = CGPoint(x: cx + innerR * cosA, y: cy - innerR * sinA)

                var path = Path()
                path.move(to: inner)
                path.addLine(to: outer)

                if isActive {
                    let r = min(1.0, t * 1.6)
                    let g = max(0.0, 0.75 - t * 0.95)
                    ctx.stroke(path, with: .color(Color(red: r, green: g, blue: 0.05)),
                               style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                } else {
                    ctx.stroke(path, with: .color(.secondary.opacity(0.18)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text("0°")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .offset(x: 4, y: 0)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(maxTemp)°")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .offset(x: -4, y: 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.75)) {
                animated = fraction
            }
        }
        .onChange(of: fraction) { newValue in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                animated = newValue
            }
        }
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}

#Preview {
    HStack(spacing: 16) {
        TemperatureGaugeView(temperature: 82, title: "CPU", icon: "cpu")
        TemperatureGaugeView(temperature: 61, title: "GPU", icon: "gpu")
    }
    .padding()
    .frame(width: 620)
}
