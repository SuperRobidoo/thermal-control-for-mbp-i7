//
//  FanRPMView.swift
//  Thermal Control
//

import SwiftUI

struct FanRPMView: View {
    @EnvironmentObject private var monitor: ThermalMonitor

    private var fc: SMCFanController { monitor.fanController }

    @State private var sliderRPM: Double = 2000
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
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer()

                modeBadge
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

            // ── Smart mode target ──
            if fc.mode == .smart {
                HStack {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("Smart target")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: String(format: "%d RPM", Int(fc.smartTargetRPM)))
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }

            // ── Manual mode target ──
            if fc.mode == .manual {
                HStack {
                    Text("Target")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: String(format: "%d RPM", Int(fc.targetRPM)))
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }

            // ── Mode toggle (only when fan control is available) ──
            if fc.isAvailable {
                HStack(spacing: 0) {
                    modeButton(label: "Auto",   isActive: fc.mode == .auto,   accent: .secondary) {
                        monitor.setFanControlMode(.auto)
                    }
                    modeButton(label: "Smart",  isActive: fc.mode == .smart,  accent: .orange) {
                        monitor.setFanControlMode(.smart)
                    }
                    modeButton(label: "Manual", isActive: fc.mode == .manual, accent: .blue) {
                        monitor.setFanControlMode(.manual)
                        sliderRPM = max(fc.minRPM, min(fc.maxRPM,
                                   fc.targetRPM > 0 ? fc.targetRPM : fc.minRPM))
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            // ── Manual RPM slider ──
            if fc.isAvailable && fc.mode == .manual {
                VStack(spacing: 4) {
                    Slider(
                        value: $sliderRPM,
                        in: fc.minRPM...fc.maxRPM,
                        step: 100
                    ) { editing in
                        if !editing { fc.setManual(rpm: sliderRPM) }
                    }
                    .tint(.blue)

                    HStack {
                        Text(verbatim: String(format: "%d", Int(fc.minRPM)))
                        Spacer()
                        Text(verbatim: String(format: "%d RPM", Int(sliderRPM)))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.blue)
                        Spacer()
                        Text(verbatim: String(format: "%d", Int(fc.maxRPM)))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }

            // ── Smart mode explanation ──
            if fc.isAvailable && fc.mode == .smart {
                Text("Monitors thermal level every 0.5 s and boosts fan before throttling occurs.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ── Setup prompt ──
            if !fc.isAvailable {
                Text("Fan control available after privilege setup")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, x: 0, y: 2)
        .onAppear {
            sliderRPM = max(fc.minRPM, min(fc.maxRPM,
                        fc.targetRPM > 0 ? fc.targetRPM : fc.minRPM))
        }
        .onChange(of: fc.targetRPM) { rpm in
            if fc.mode == .manual {
                sliderRPM = max(fc.minRPM, min(fc.maxRPM, rpm))
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var modeBadge: some View {
        switch fc.mode {
        case .smart:
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("Smart")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.orange, in: Capsule())
        case .manual:
            Text("Manual")
                .font(.system(size: 10, weight: .semibold))
                .fixedSize()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.blue, in: Capsule())
        case .auto:
            EmptyView()
        }
    }

    @ViewBuilder
    private func modeButton(label: String, isActive: Bool, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    isActive ? accent.opacity(0.85) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .foregroundStyle(isActive ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func startSpinning() {
        withAnimation(.linear(duration: rotationDuration).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}
