//
//  NotificationManager.swift
//  Thermal Control
//

import UserNotifications
import Foundation
import os.log

private let notifLog = Logger(subsystem: "com.thermalcontrol", category: "notifications")

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

    // MARK: - Safety-critical alerts
    // These bypass user notification preferences and cooldown because hardware
    // risk takes precedence over notification-fatigue concerns.

    /// Fires when CPU temperature reaches or exceeds the emergency warning threshold (97°C).
    /// Fan control is already being forced to max when this is called.
    func sendOverheatWarning(temp: Double) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ CPU Overheating"
        content.body  = String(format: "CPU temperature reached %.0f°C. Fans set to maximum.", temp)
        content.sound = .defaultCritical
        content.categoryIdentifier = "THERMAL_SAFETY_CRITICAL"
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .critical
        }
        notifLog.error("Overheat warning sent: \(temp, privacy: .public)°C")
        post(content, identifier: "overheat-warning")
    }

    /// Fires when CPU temperature reaches or exceeds Tj,max (100°C).
    /// System sleep is initiated when this is called.
    func sendCriticalOverheatAlert(temp: Double) {
        let content = UNMutableNotificationContent()
        content.title = "🔥 Critical CPU Temperature"
        content.body  = String(format: "CPU reached %.0f°C — at junction maximum. System will sleep to prevent damage.", temp)
        content.sound = .defaultCritical
        content.categoryIdentifier = "THERMAL_SAFETY_CRITICAL"
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .critical
        }
        notifLog.critical("Critical overheat alert sent: \(temp, privacy: .public)°C")
        post(content, identifier: "overheat-critical")
    }

    /// Fires when a fan stall is confirmed (3 consecutive zero-RPM samples while CPU is warm).
    /// Fan control has already been reverted to SMC auto by the time this fires.
    func sendFanStallAlert(rpm: Int, temp: Double) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ Fan Stall Detected"
        content.body  = String(format: "Fan speed dropped to %d RPM at %.0f°C. Fan control reverted to Auto.", rpm, temp)
        content.sound = .defaultCritical
        content.categoryIdentifier = "THERMAL_SAFETY_CRITICAL"
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .critical
        }
        notifLog.error("Fan stall alert sent: RPM=\(rpm, privacy: .public) temp=\(temp, privacy: .public)°C")
        post(content, identifier: "fan-stall")
    }

    // MARK: - Private helpers

    private func post(_ content: UNMutableNotificationContent, identifier: String) {
        let request = UNNotificationRequest(
            identifier: "\(identifier)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                notifLog.error("Failed to post notification '\(identifier, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func registerCategories() {
        let viewHistory = UNNotificationAction(
            identifier: "VIEW_HISTORY",
            title: "View History",
            options: [.foreground]
        )
        let throttleCategory = UNNotificationCategory(
            identifier: "THERMAL_THROTTLE",
            actions: [viewHistory],
            intentIdentifiers: [],
            options: []
        )

        // Safety-critical category: no actions, not dismissable until acknowledged.
        let safetyCategory = UNNotificationCategory(
            identifier: "THERMAL_SAFETY_CRITICAL",
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([throttleCategory, safetyCategory])
    }
}
