//
//  WriteProgress.swift
//  Vitrea
//
//  写入进度的「显示层」。
//
//  为什么需要单独一层：
//  底层（Rust）只在**每个文件写完**时给一次信号，文件之间还有 500ms 冷却；
//  直接把真实进度丢给 UI，就会出现「30% → 62% → 95%」这种大跳变。
//
//  这里做两件事：
//    1. `setTarget` 只接受**单调不减**的真实进度（阶段边界 + 文件级计数）；
//    2. 一个 20Hz 的显示定时器把显示值往目标推，**每 tick 最多 +1%**，
//       所以屏幕上永远是 1% 1% 地往上走，不会一次跳一大格。
//
//  代价：真实操作很快结束时，显示值要花 1–3 秒追上去。这是「不跳变」的必然取舍。
//

import Foundation
import SwiftUI

@MainActor
final class WriteProgressModel: ObservableObject {

    /// 0…100，单调递增
    @Published private(set) var percent: Int = 0
    /// 当前阶段文案
    @Published private(set) var stage: String = "准备中…"

    // MARK: 内部

    /// 真实目标（0…1，单调不减）
    private var target: Double = 0
    /// 当前显示值（0…1，单调不减）
    private var shown: Double = 0

    private var timer: Timer?
    /// 是否已进入收尾（允许稍快，避免长尾）
    private var finishing = false
    /// 已对外广播过的百分比，避免重复回调
    private var lastEmitted = -1

    /// 每次 tick 最多推进多少（1%）
    private let stepPerTick = 0.01
    /// 收尾阶段每 tick 最多推进多少（2%）
    private let finishingStepPerTick = 0.02
    /// 驱动频率：每 100ms 走 1% → 满量程最快约 10 秒。
    /// 这个节奏既不会慢到看着卡住，也不会快到让灵动岛来不及跟。
    private let tickInterval: TimeInterval = 0.1

    /// 百分比变化时的回调（用来刷新实时活动）
    private var onPercentChange: ((Int, String) -> Void)?

    /// 未完成前，目标值最多推到 99%，把最后 1% 留给真正的完成
    private let unfinishedCap = 0.99

    // MARK: 生命周期

    func begin(onPercentChange: ((Int, String) -> Void)? = nil) {
        self.onPercentChange = onPercentChange
        target = 0
        shown = 0
        finishing = false
        lastEmitted = -1
        percent = 0
        stage = "准备中…"
        startTimer()
    }

    /// 结束并复位（不会自动把显示值推到 100）
    func reset() {
        stopTimer()
        target = 0
        shown = 0
        finishing = false
        lastEmitted = -1
        percent = 0
        stage = "准备中…"
        onPercentChange = nil
    }

    // MARK: 输入

    /// 更新真实进度（单调：比当前目标小则忽略）
    /// - Parameters:
    ///   - fraction: 0…1
    ///   - stage: 阶段文案
    func setTarget(_ fraction: Double, stage newStage: String) {
        let clamped = min(max(fraction, 0), 1)
        if clamped > target { target = min(clamped, unfinishedCap) }
        if stage != newStage { stage = newStage }
        ensureTimerRunning()
    }

    /// 全部完成：把目标放到 100%，并允许收尾加速
    func finish(stage newStage: String = "完成") {
        target = 1
        finishing = true
        stage = newStage
        ensureTimerRunning()
    }

    // MARK: 定时器

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
        // 用 .common 模式：滚动列表时也不会被 RunLoop 暂停
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func ensureTimerRunning() {
        if timer == nil { startTimer() }
    }

    /// 推进一次显示值
    private func advance() {
        guard shown < target else {
            if shown >= 1 {
                stopTimer()
                emitIfNeeded()
            }
            return
        }

        let step = finishing ? finishingStepPerTick : stepPerTick
        shown = min(target, shown + step)
        emitIfNeeded()

        if shown >= 1 { stopTimer() }
    }

    private func emitIfNeeded() {
        let value = Int((shown * 100).rounded(.down))
        guard value != lastEmitted else { return }
        lastEmitted = value
        percent = value
        onPercentChange?(value, stage)
    }

    // MARK: 等待显示值走满

    /// 写入实际已经结束、但显示值还在追的时候，等它走到 100。
    /// 有超时兜底，避免异常情况下卡住收尾。
    func waitUntilComplete(timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while percent < 100 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }
}
