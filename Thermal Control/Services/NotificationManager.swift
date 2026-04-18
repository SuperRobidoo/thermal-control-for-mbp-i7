//
//  NotificationManager.swift
//  Thermal Control
//

import UserNotifications
import Foundation

final class NotificationManager {
    static let shared = NotificationManager()
    private var lastAlertDate: Date?
    private let settings = NotificationSettings.shared

    private init() {
        registerCategories()
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func checkPermission(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus) }
        }
    }

    func sendThrottleAlert(pressure: ThermalPressure) {
        guard settings.isEnabled else { return }
        guard pressure.severity >= settings.threshold.severity else { return }

        let now = Date()
        if let last = lastAlertDate, now.timeIntervalSince(last) < Double(settings.cooldownSeconds) { return }
        lastAlertDate = now

        let content = UNMutableNotificationContent()
        content.title = "Thermal Throttling Detected"
        content.body = settings.customMessage.isEmpty
            ? "CPU thermal pressure: \(pressure.displayName)"
            : settings.customMessage
        content.sound = .default
        content.categoryIdentifier = "THERMAL_THROTTLE"

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func registerCategories() {
        let viewHistory = UNNotificationAction(
            identifier: "VIEW_HISTORY",
            title: "View History",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "THERMAL_THROTTLE",
            actions: [viewHistory],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
