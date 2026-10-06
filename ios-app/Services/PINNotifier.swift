//
//  PINNotifier.swift
//  Vitrea
//
//  配对 PIN 本地通知：用户切到「设置」输码时看不到 App 界面，
//  用系统通知把 PIN 推到通知中心 / 锁屏，避免来回切应用抄码。
//

import Foundation
import UserNotifications

enum PINNotifier {

    private static let pinIdentifier = "pairing.pin"
    private static let doneIdentifier = "pairing.done"

    /// 请求通知授权（alert + 声音；失败静默降级，不阻塞配对流程）
    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// PIN 出现：立即弹横幅 + 常驻通知中心，正文直接带码，可反复下拉查看
    static func postPIN(_ pin: String) {
        let content = UNMutableNotificationContent()
        content.title = "配对码：\(pin)"
        content.body = "在 设置 › 隐私与安全性 › 开发者模式 › 配对 中输入此码完成配对"
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: pinIdentifier,
            content: content,
            trigger: nil   // 立即送达
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 配对成功：清掉 PIN 通知，改为成功提示
    static func postPaired(deviceName: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [pinIdentifier])

        let content = UNMutableNotificationContent()
        content.title = "配对成功"
        content.body = "\(deviceName) 已与本机完成配对，可以返回Vitrea继续操作"
        content.sound = .default

        center.add(UNNotificationRequest(
            identifier: doneIdentifier,
            content: content,
            trigger: nil
        ))
    }

    /// 配对取消 / 失败：撤掉还在通知中心里的 PIN，避免误导
    static func withdrawPIN() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [pinIdentifier])
    }
}
