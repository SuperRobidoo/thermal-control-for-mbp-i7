//
//  FanRPMView.swift
//  Thermal Control
//

import SwiftUI

struct FanRPMView: View {
    @EnvironmentObject private var monitor: ThermalMonitor

    @State private var rotation: Double = 0

    private var rpm: Int { monitor.fanRPM }

    private var rotationDuration: Double {
        guard rpm > 0 else { return 4.0 }
        return Swift.max(0.4, 4.0 - (Double(min(rpm, 6000)) / 6000.0) * 3.6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // ── Header ──
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 26, height: 26)
                    Image(systemName: "fan.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(rotation))
                        .onAppear { startSpinning() }
                        .onChange(of: rpm) { _ in startSpinning() }
                }
                Text("Fan Speed")
                    .font(.system(size: 13, weight: .semibold))
            }

            // ── Actual RPM ──
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: String(rpm))
                    .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("RPM")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            // ── Range info ──
            let fc = monitor.fanController
            if fc.isAvailable {
                HStack {
                    Text(verbatim: String(format: "Min %d", Int(fc.minRPM)))
                    Spacer()
                    Text(verbatim: String(format: "Max %d", Int(fc.maxRPM)))
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, x: 0, y: 2)
    }

    private func startSpinning() {
        withAnimation(.linear(duration: rotationDuration).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}
