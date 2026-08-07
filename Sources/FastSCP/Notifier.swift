import AppKit
import Foundation
import FastSCPCore
import UserNotifications

enum Notifier {
    /// 通知左侧的 App 图标由系统按 bundle ID 从 LaunchServices 解析，
    /// App 无法通过 API 指定（`UNNotificationAttachment` 只影响右侧缩略图）。
    /// 图标不显示时，通常是 LaunchServices 里该 bundle 的图标记录没建立好，
    /// 重新登记 App 即可让系统重新解析。
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                DiagLog.log("[app] notification auth granted=\(granted) error=\(error.map(String.init(describing:)) ?? "nil")")
            }
        logSettings()
    }

    static func logSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DiagLog.log("""
                [app] notification settings auth=\(s.authorizationStatus.rawValue) \
                alertStyle=\(s.alertStyle.rawValue) alert=\(s.alertSetting.rawValue) \
                center=\(s.notificationCenterSetting.rawValue)
                """)
        }
    }

    static func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                DiagLog.log("[app] notification add FAILED: \(error)")
            }
        }
    }
}
