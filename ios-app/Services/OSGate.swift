//
//  OSGate.swift
//  Vitrea
//
//  启动期系统版本闸门：
//  · iPad 不支持（直接拦截）
//  · iOS 18.0 – 26.x 完整可用
//  · iOS 27.0 – 27.2 b2 可用；27.2 b3 起底层 airlift 漏洞已修补，不能继续
//

import SwiftUI
import UIKit

enum OSGate {

    /// 当前设备 / 系统版本是否仍可使用
    static var isAllowed: Bool {
        if UIDevice.current.userInterfaceIdiom == .pad { return false }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion >= 18 && v.majorVersion <= 26 { return true }
        if v.majorVersion == 27 && v.minorVersion <= 2 { return true }
        return false
    }

    static var reasonText: String {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return "iPad 当前不在支持范围内，请使用 iPhone。"
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion >= 18 && v.majorVersion <= 26 {
            return "此 iOS / iPadOS 版本不在支持范围内。"
        }
        if v.majorVersion == 27 && v.minorVersion <= 2 {
            return "此 iOS 版本不在支持范围内。"
        }
        return "此 iOS 版本不在支持范围内。"
    }
}

struct OSGateView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 56, weight: .light))
                    .foregroundColor(.secondary)
                Text("Unsupported System Version")
                    .font(.title2.bold())
                Text(OSGate.reasonText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 2) {
                    Text("Supported: iOS 18.0 – 26.x")
                    Text("Or iOS 27.0 – 27.2 b2")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                Text("iPad 当前不支持。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 32)
        }
    }
}