//
//  MainDashboardView.swift
//  Thermal Control
//

import SwiftUI
import LocalAuthentication

struct MainDashboardView: View {
    @EnvironmentObject private var monitor: ThermalMonitor
    @State private var showHistory = false
    @State private var showNotificationSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {

                // ── Privilege setup banner ──
                if monitor.needsPrivilegeSetup {
                    PrivilegeSetupBanner()
                }

                // ── Row 1: Temperature gauges + Fan ──
                HStack(alignment: .top, spacing: 12) {
                    TemperatureGaugeView(
                        temperature: monitor.currentTemperature,
                        title: "CPU Temperature", icon: "cpu"
                    )
                    .frame(maxWidth: .infinity)

                    TemperatureGaugeView(
                        temperature: monitor.gpuTemperature,
                        title: "GPU Temperature", icon: "memorychip"
                    )
                    .frame(maxWidth: .infinity)

                    FanRPMView()
                        .frame(width: 195)
                }

                // ── Row 2: Throttle state + Risk assessment ──
                HStack(spacing: 12) {
                    ThrottleStateCard(
                        pressure: monitor.currentPressure,
                        isThrottling: monitor.isThrottling
                    )
                    RiskAssessmentCard(
                        cpuTemperature: monitor.currentTemperature,
                        cpuThermalLevel: monitor.cpuThermalLevel,
                        prochotCount: monitor.prochotCount,
                        isThrottling: monitor.isThrottling
                    )
                }

                // ── Row 3: Thermal level bars ──
                HStack(spacing: 12) {
                    ThermalLevelGaugeView(label: "CPU Thermal",
                                          value: monitor.cpuThermalLevel, icon: "cpu")
                    ThermalLevelGaugeView(label: "GPU Thermal",
                                          value: monitor.gpuThermalLevel, icon: "gpu")
                    ThermalLevelGaugeView(label: "IO Thermal",
                                          value: monitor.ioThermalLevel,
                                          icon: "square.3.layers.3d")
                }

                // ── Row 4: Power limits ──
                PowerLimitRowView(
                    cpuPLimit:        monitor.cpuPLimit,
                    gpuPLimitInt:     monitor.gpuPLimitInt,
                    gpuPLimitExt:     monitor.gpuPLimitExt,
                    prochotCount:     monitor.prochotCount,
                    packagePowerW:    monitor.packagePowerW,
                    cpuFreqNominalPct: monitor.cpuFreqNominalPct
                )

                // Error banner
                if let err = monitor.errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 12))
                }

                Divider()

                // ── Action buttons ──
                HStack(spacing: 12) {
                    Button { showHistory = true } label: {
                        Label("View History", systemImage: "chart.line.uptrend.xyaxis")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button { showNotificationSettings = true } label: {
                        Label("Notifications", systemImage: "bell")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.bottom, 4)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, minHeight: 540)
        .navigationTitle("Thermal Control")
        .toolbar {
            ToolbarItem(placement: .status) {
                if monitor.isRunning {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("Live").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label("Not running", systemImage: "pause.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoricalGraphView()
                .environmentObject(monitor)
                .frame(minWidth: 600, minHeight: 400)
        }
        .sheet(isPresented: $showNotificationSettings) {
            NotificationSettingsView()
        }
    }
}

// MARK: - Throttle State Card

private struct ThrottleStateCard: View {
    var pressure: ThermalPressure
    var isThrottling: Bool

    private var statusColor: Color {
        switch pressure {
        case .nominal:  return Color(red: 0.18, green: 0.72, blue: 0.38)
        case .moderate: return Color(red: 1.0,  green: 0.70, blue: 0.0)
        case .heavy:    return Color(red: 1.0,  green: 0.40, blue: 0.0)
        case .trapping: return Color(red: 0.91, green: 0.20, blue: 0.12)
        }
    }

    private var iconName: String {
        switch pressure {
        case .nominal:  return "checkmark.circle.fill"
        case .moderate: return "thermometer.medium"
        case .heavy:    return "flame.fill"
        case .trapping: return "exclamationmark.octagon.fill"
        }
    }

    private var subtitle: String {
        switch pressure {
        case .nominal:  return "Running at full speed"
        case .moderate: return "Slight performance reduction"
        case .heavy:    return "Performance significantly reduced"
        case .trapping: return "CPU is hard-throttled"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Thermal Pressure")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(pressure.displayName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(statusColor)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Pressure level bar (4 segments: Nominal / Moderate / Heavy / Trapping)
            HStack(spacing: 4) {
                ForEach(ThermalPressure.allCases, id: \.self) { level in
                    Capsule()
                        .fill(level.severity <= pressure.severity
                              ? statusColor
                              : Color.secondary.opacity(0.15))
                        .frame(maxWidth: .infinity, minHeight: 6, maxHeight: 6)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(statusColor.opacity(0.18), lineWidth: 1))
        .animation(.easeInOut(duration: 0.35), value: pressure)
    }
}

// MARK: - Risk Assessment Card

private struct RiskAssessmentCard: View {
    var cpuTemperature: Double
    var cpuThermalLevel: Int
    var prochotCount: Int
    var isThrottling: Bool

    /// 0 – 1 score blending temperature, thermal level and prochot events
    private var riskScore: Double {
        let tempFactor  = ((cpuTemperature - 55) / 65).clamped(to: 0...1)
        let levelFactor = Double(cpuThermalLevel) / 100.0
        let procFactor  = Double(min(prochotCount, 5)) / 5.0
        return (tempFactor * 0.45 + levelFactor * 0.45 + procFactor * 0.10)
            .clamped(to: 0...1)
    }

    private var riskLabel: String {
        switch riskScore {
        case ..<0.25: return "Low"
        case 0.25..<0.50: return "Moderate"
        case 0.50..<0.75: return "High"
        default: return "Critical"
        }
    }

    private var riskColor: Color {
        switch riskScore {
        case ..<0.25: return Color(red: 0.18, green: 0.72, blue: 0.38)
        case 0.25..<0.50: return Color(red: 1.0, green: 0.70, blue: 0.0)
        case 0.50..<0.75: return Color(red: 1.0, green: 0.40, blue: 0.0)
        default: return Color(red: 0.91, green: 0.20, blue: 0.12)
        }
    }

    private var riskDescription: String {
        if isThrottling { return "Active throttling — CPU performance is reduced." }
        switch riskScore {
        case ..<0.25:    return "System thermals are well within limits."
        case 0.25..<0.50: return "CPU is warming up. Throttling is unlikely."
        case 0.50..<0.75: return "Elevated thermals. Throttling may occur soon."
        default:         return "Critical heat load. Throttling is imminent."
        }
    }

    /// Number of filled segments out of 5
    private var filledSegments: Int {
        max(1, Int((riskScore * 5).rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Throttle Risk")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(riskLabel)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(riskColor)
                Spacer()
                Text(String(format: "%.0f%%", riskScore * 100))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // 5-segment risk bar
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(i < filledSegments
                              ? riskColor
                              : Color.secondary.opacity(0.15))
                        .frame(maxWidth: .infinity, minHeight: 6, maxHeight: 6)
                }
            }

            Text(riskDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, x: 0, y: 2)
        .animation(.easeInOut(duration: 0.35), value: riskScore)
    }
}

// MARK: - Privilege setup banner

private struct PrivilegeSetupBanner: View {
    @EnvironmentObject private var monitor: ThermalMonitor
    @State private var isSettingUp = false
    @State private var setupError: String?

    private var authMethod: (icon: String, label: String) {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            return ("key.fill", "Grant Access")
        }
        switch ctx.biometryType {
        case .touchID:  return ("touchid",       "Authenticate with Touch ID")
        case .faceID:   return ("faceid",        "Authenticate with Face ID")
        case .opticID:  return ("opticid",       "Authenticate with Optic ID")
        default:
            // Apple Watch or password
            return ("applewatch", "Authenticate with Apple Watch or Password")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permission Required").font(.headline)
                    Text("One-time admin access needed to run powermetrics.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let err = setupError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Button {
                isSettingUp = true; setupError = nil
                monitor.setupPrivileges { success, error in
                    isSettingUp = false
                    if !success { setupError = error ?? "Setup failed." }
                }
            } label: {
                if isSettingUp {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Setting up…") }
                } else {
                    Label(authMethod.label, systemImage: authMethod.icon)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSettingUp)
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
    }
}

#Preview {
    MainDashboardView().environmentObject(ThermalMonitor())
}

// MARK: - Helper

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
