//
//  NotificationSettings.swift
//  Thermal Control
//

import Foundation
import Combine

final class NotificationSettings: ObservableObject {
    static let shared = NotificationSettings()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "notif_enabled") }
    }
    @Published var threshold: ThermalPressure {
        didSet { UserDefaults.standard.set(threshold.rawValue, forKey: "notif_threshold") }
    }
    @Published var customMessage: String {
        didSet { UserDefaults.standard.set(customMessage, forKey: "notif_message") }
    }
    @Published var cooldownSeconds: Int {
        didSet { UserDefaults.standard.set(cooldownSeconds, forKey: "notif_cooldown") }
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: "notif_enabled") as? Bool ?? true
        let thresholdRaw = UserDefaults.standard.string(forKey: "notif_threshold") ?? ThermalPressure.heavy.rawValue
        threshold = ThermalPressure(rawValue: thresholdRaw) ?? .heavy
        customMessage = UserDefaults.standard.string(forKey: "notif_message") ?? "CPU thermal throttling detected!"
        cooldownSeconds = UserDefaults.standard.object(forKey: "notif_cooldown") as? Int ?? 60
    }
}
