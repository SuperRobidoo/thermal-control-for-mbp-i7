//
//  NotificationSettingsView.swift
//  Thermal Control
//

import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = NotificationSettings.shared
    @State private var authStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            Form {
                Section("Alerts") {
                    Toggle("Enable Throttle Alerts", isOn: $settings.isEnabled)

                    if settings.isEnabled {
                        Picker("Alert Threshold", selection: $settings.threshold) {
                            ForEach(ThermalPressure.allCases.filter { $0 != .nominal }, id: \.self) { pressure in
                                Text(pressure.displayName).tag(pressure)
                            }
                        }
                        .pickerStyle(.segmented)

                        LabeledContent("Cooldown") {
                            Stepper("\(settings.cooldownSeconds)s", value: $settings.cooldownSeconds, in: 10...300, step: 10)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom Message")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("Alert message", text: $settings.customMessage)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                Section("Permission") {
                    HStack {
                        Image(systemName: authStatus == .authorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(authStatus == .authorized ? .green : .red)
                        Text(authStatus == .authorized ? "Notifications allowed" : "Notifications not allowed")
                            .font(.subheadline)
                        Spacer()
                        if authStatus != .authorized {
                            Button("Request") {
                                NotificationManager.shared.requestPermission()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { checkPermission() }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Notification Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { checkPermission() }
        }
        .frame(minWidth: 380, minHeight: 300)
    }

    private func checkPermission() {
        NotificationManager.shared.checkPermission { status in
            authStatus = status
        }
    }
}

#Preview {
    NotificationSettingsView()
}
