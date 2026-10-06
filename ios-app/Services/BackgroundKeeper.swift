//
//  BackgroundKeeper.swift
//  Vitrea
//
//  让耗时任务在切到后台后继续跑完（写入卡面、跨应用扫描、清理都用它）。
//
//  两道保险：
//    1. `beginBackgroundTask` —— 系统给的标准宽限期（通常几十秒）。
//    2. **静音音频会话** —— 本 App 已在 Info.plist 声明 `UIBackgroundModes: audio`
//       （原本用于配对期保活），这里复用同一条通道：起一个只输出 0 采样的
//       AVAudioEngine，音频会话保持 active，App 就不会被挂起。
//       用 `.mixWithOthers`，所以不会打断用户正在听的音乐。
//
//  多个任务可能重叠（比如一边写卡一边扫描），所以内部用**引用计数**：
//  只有第一个 `begin` 真正开启保活，最后一个 `end` 才关闭。
//  每个 `begin` 必须配对一次 `end`（建议用 `defer`）。
//

import AVFoundation
import UIKit

@MainActor
final class BackgroundKeeper {

    static let shared = BackgroundKeeper()

    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    /// 正在使用保活的任务数
    private var users = 0

    /// 当前是否处于保活状态（供 UI / 诊断查看）
    private(set) var isKeeping = false

    /// 当前生效的 reason（第一个使用者决定，便于排查）
    private(set) var currentReason: String = ""

    // MARK: 开始

    func begin(reason: String) {
        users += 1
        guard users == 1 else { return }   // 已经在保活，只加计数

        currentReason = reason

        // ① 系统宽限期
        taskID = UIApplication.shared.beginBackgroundTask(withName: reason) { [weak self] in
            // 到期回调：系统马上要挂起我们了，主动收尾避免被强杀
            Task { @MainActor in self?.forceEnd() }
        }

        // ② 静音音频保活
        startSilentAudio()

        isKeeping = (engine != nil) || (taskID != .invalid)
    }

    // MARK: 结束

    func end() {
        users = max(0, users - 1)
        guard users == 0 else { return }   // 还有别的任务在用
        forceEnd()
    }

    private func forceEnd() {
        users = 0
        currentReason = ""

        stopSilentAudio()

        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        isKeeping = false
    }

    // MARK: 静音音频

    private func startSilentAudio() {
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // playback + mixWithOthers：能拿到后台执行权，又不抢占用户的音乐
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let format = engine.mainMixerNode.outputFormat(forBus: 0)

            // 只吐 0 采样；render block 必须实时安全，不做分配
            let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in buffers {
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                }
                _ = frameCount
                return noErr
            }

            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            try engine.start()

            self.engine = engine
            self.sourceNode = node
        } catch {
            // 起不来就只靠 beginBackgroundTask 的宽限期，不阻断业务
            engine = nil
            sourceNode = nil
        }
    }

    private func stopSilentAudio() {
        engine?.stop()
        engine = nil
        sourceNode = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
