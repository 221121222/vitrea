//
//  WriteActivityAttributes.swift
//  Vitrea
//
//  写入卡面的实时活动（Live Activity）共享模型。
//
//  ⚠️ 这个文件**同时被两个 target 编译**：
//    · 主 App（Vitrea）—— 负责 request / update / end
//    · 小组件扩展（VitreaWidgets）—— 负责灵动岛与锁屏的呈现
//  两边的类型必须逐字节一致，所以放在 `ios-app/Shared/` 下共用一份源码。
//

import ActivityKit
import Foundation

/// 一次「写入卡面」的实时活动
struct WriteActivityAttributes: ActivityAttributes {

    /// 会随进度变化的部分
    public struct ContentState: Codable, Hashable {
        /// 0…100，单调递增，每次只 +1
        var percent: Int
        /// 当前阶段文案，如「正在写入 (3/8)…」
        var stage: String
        /// 正在写入的卡（短标签）
        var cardLabel: String
        /// 已完成张数 / 总张数
        var done: Int
        var total: Int
        /// 失败张数
        var failed: Int
        /// 是否已结束（用于切换成结果态）
        var finished: Bool

        init(percent: Int = 0,
             stage: String = "准备中…",
             cardLabel: String = "",
             done: Int = 0,
             total: Int = 0,
             failed: Int = 0,
             finished: Bool = false) {
            self.percent = percent
            self.stage = stage
            self.cardLabel = cardLabel
            self.done = done
            self.total = total
            self.failed = failed
            self.finished = finished
        }
    }

    /// 固定部分：标题
    var title: String
}
