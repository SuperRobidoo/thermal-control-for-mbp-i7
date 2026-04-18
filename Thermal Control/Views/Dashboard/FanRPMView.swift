//
//  FanRPMView.swift
//  Thermal Control
//

import SwiftUI

struct FanRPMView: View {
    var rpm: Int
    @ObservedObject var fanController: SMCFanController

    private var rotationDuration: Double {
        guard rpm > 0 else { return 4.0 }
        let clamped = Double(min(rpm, 6000))
        return Swift.max(0.4, 4.0 - (clamped / 6000.0) * 3.6)
    }

    @State private var rotation: Double = 0
    @State private var sliderRPM: Double = 2000

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

                Spacer()

                if fanController.isAvailable && fanController.isManual {
                    Text("Manual")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.orange, in: Capsule())
                }
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

            // ── Target RPM (manual mode) ──
            if fanController.isManual {
                HStack {
                    Text("Target")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: String(format: "%d RPM", Int(fanController.targetRPM)))
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }

            // ── Auto / Manual toggle ──
            if fanController.isAvailable {
                HStack(spacing: 0) {
                    modeButton(label: "Auto",   isActive: !fanController.isManual) {
                        fanController.setAuto()
                    }
                    modeButton(label: "Manual", isActive:  fanController.isManual) {
                        fanController.setManual(rpm: sliderRPM)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            // ── Manual RPM slider ──
            if fanController.isAvailable && fanController.isManual {
                VStack(spacing: 4) {
                    Slider(
                        value: $sliderRPM,
                        in: fanController.minRPM...fanController.maxRPM,
                        step: 100
                    ) { editing in
                        if !editing {
                            fanController.setManual(rpm: sliderRPM)
                        }
                    }
                    .tint(.orange)

                    HStack {
                        Text(verbatim: String(format: "%d", Int(fanController.minRPM)))
                        Spacer()
                        Text(verbatim: String(format: "%d RPM", Int(sliderRPM)))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.orange)
                        Spacer()
                        Text(verbatim: String(format: "%d", Int(fanController.maxRPM)))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }

            // ── Setup prompt ──
            if !fanController.isAvailable {
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
            sliderRPM = max(fanController.minRPM,
                            min(fanController.maxRPM, fanController.targetRPM))
        }
        .onChange(of: fanController.targetRPM) { rpm in
            sliderRPM = max(fanController.minRPM,
                            min(fanController.maxRPM, rpm))
        }
    }

    @ViewBuilder
    private func modeButton(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    isActive
                        ? Color(nsColor: .controlAccentColor).opacity(0.85)
                        : Color.clear,
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

