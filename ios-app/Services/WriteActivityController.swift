//
//  WriteActivityController.swift
//  Vitrea
//
//  实时活动（Live Activity）主 App 侧：开始 / 更新 / 结束。
//  呈现由 `VitreaWidgets` 扩展负责（灵动岛紧凑态显示百分比、展开态显示进度条）。
//
//  注意：
//    · 用户可在「设置 → 灵动岛 / 实时活动」里关掉，`Activity.request` 会抛错 ——
//      这里全部静默降级，写入流程不受影响。
//    · 更新做节流（默认 0.15s），避免高频刷新被系统限流；
//      应用内百分比仍然是每 1% 一帧，灵动岛最差也就 2% 一跳。
//

import ActivityKit
import Foundation

@MainActor
final class WriteActivityController {

    static let shared = WriteActivityController()

    private var activity: Activity<WriteActivityAttributes>?
    private var state = WriteActivityAttributes.ContentState()

    /// 由 `setContext` 维护的上下文（卡名 / 张数），与百分比分开更新，
    /// 这样百分比回调不需要捕获视图状态，避免拿到过期快照。
    private var done = 0
    private var failed = 0

    /// 节流：两次下发的最小间隔。
    ///
    /// 这个值**不能太小**：灵动岛每次内容变化都会走一段过渡动画，
    /// 如果更新间隔短于动画时长，屏幕上会一直处于「动画中间态」，
    /// 数字看起来就是**糊的**（之前 0.15s 就是这个毛病）。
    /// 0.4s 让每次过渡都播完；应用内百分比仍然是每 1% 一帧。
    private let minUpdateInterval: TimeInterval = 0.4
    private var lastSentAt = Date.distantPast
    private var pendingWork: DispatchWorkItem?

    private init() {}

    /// 系统是否允许实时活动
    var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: 开始

    func start(title: String = "写入卡面", cardLabel: String, total: Int) {
        guard isEnabled else { return }
        guard activity == nil else { return }

        done = 0
        failed = 0
        state = WriteActivityAttributes.ContentState(
            percent: 0,
            stage: total > 1 ? "准备写入 \(total) 张卡…" : "准备中…",
            cardLabel: cardLabel,
            done: 0,
            total: total,
            failed: 0,
            finished: false
        )

        let attributes = WriteActivityAttributes(title: title)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            lastSentAt = Date()
        } catch {
            // 用户关闭了实时活动 / 系统不允许 —— 静默降级
            activity = nil
        }
    }

    // MARK: 上下文（张数 / 卡名）

    /// 批量进度里除了百分比以外的信息，单独更新（不触发下发）
    func setContext(cardLabel: String, done: Int, failed: Int, total: Int) {
        guard activity != nil else { return }
        self.done = done
        self.failed = failed
        state.cardLabel = cardLabel
        state.total = total
    }

    // MARK: 更新

    /// 百分比变化时调用（已在 1% 粒度上）
    func update(percent: Int, stage: String) {
        guard let activity else { return }

        state.percent = percent
        state.stage = stage
        state.done = done
        state.failed = failed

        let now = Date()
        let elapsed = now.timeIntervalSince(lastSentAt)
        if elapsed >= minUpdateInterval {
            push(activity)
        } else {
            // 合并到下一次窗口，避免丢最后一帧
            pendingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let activity = self.activity else { return }
                self.push(activity)
            }
            pendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (minUpdateInterval - elapsed), execute: work)
        }
    }

    private func push(_ activity: Activity<WriteActivityAttributes>) {
        lastSentAt = Date()
        pendingWork?.cancel()
        pendingWork = nil
        let snapshot = state
        Task {
            await activity.update(.init(state: snapshot, staleDate: nil))
        }
    }

    // MARK: 结束

    /// 写入全部结束：先推到 100%，稍留一下再撤掉，让用户看到结果
    func end(success: Int, failed: Int, holdFor: TimeInterval = 4) {
        guard let activity else { return }
        pendingWork?.cancel()
        pendingWork = nil

        state.percent = 100
        state.finished = true
        state.done = success + failed
        state.failed = failed
        state.stage = failed == 0
            ? "全部写入完成"
            : "成功 \(success) 张 · 失败 \(failed) 张"

        let final = state
        Task {
            await activity.update(.init(state: final, staleDate: nil))
            try? await Task.sleep(nanoseconds: UInt64(holdFor * 1_000_000_000))
            await activity.end(.init(state: final, staleDate: nil), dismissalPolicy: .immediate)
            await MainActor.run { self.activity = nil }
        }
    }

    /// 写入前清理上次残留（App 被杀掉时会留下未结束的活动）
    func endStale() {
        Task {
            for activity in Activity<WriteActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
