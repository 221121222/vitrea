//
//  CardWorkshopApp.swift
//  Vitrea
//

import SwiftUI
import AirliftFFI

@main
struct VitreaApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Rust 底座日志 → 统一日志
        al_log_init({ _, msg in
            guard let msg else { return }
            _ = String(cString: msg)
        }, nil)

        // 保留 Grappa token 符号并链入二进制（AirTraffic 客户端令牌）
        _ = ALGetGrappaToken(0, 0, 0, nil, 0, nil, nil, 0)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(nil)   // 深 / 浅双套均生效
                .onAppear {
                    model.startupProbe()
                    // 上次写入如果被系统杀掉，实时活动会残留在灵动岛 —— 启动时清掉
                    WriteActivityController.shared.endStale()
                }
        }
    }
}

@_silgen_name("ALGetGrappaToken")
func ALGetGrappaToken(
    _ inVersion: UInt32,
    _ inDeviceType: UInt32,
    _ inProtocolVersion: UInt32,
    _ outBuf: UnsafeMutablePointer<UInt8>?,
    _ maxLen: Int,
    _ outLen: UnsafeMutablePointer<Int>?,
    _ errBuf: UnsafeMutablePointer<CChar>?,
    _ errLen: Int
) -> Int32
