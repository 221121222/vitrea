//
//  WriteSheet.swift
//  Vitrea
//
//  写入面板：选择目标卡（卡识别）→ 单卡 / 批量写入 → 进度与四类错误 UI + 日志。
//

import SwiftUI
import UIKit

struct WriteSheet: View {
    let context: WriteContext
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Phase {
        case prepare, running, done(success: Int, failed: Int)
    }

    @State private var phase: Phase = .prepare
    /// 进度显示层：单调、每次只 +1%
    @StateObject private var progressModel = WriteProgressModel()
    @State private var liveLogs: [String] = []
    @State private var errors: [(cardId: String, kind: WriteErrorKind)] = []
    @State private var showLogs = false
    @State private var spinnerAngle: Double = 0
    /// 快捷指令「随机卡面」触发：进面板后自动开始写入并退回后台（只跑一次）
    @State private var didAutoStart = false

    // 批量上下文（给实时活动用）
    @State private var totalCount = 0
    @State private var doneCount = 0
    @State private var failedCount = 0

    var body: some View {
        ZStack {
            GlassContainer(tier: .thick, cornerRadius: 34) {
                VStack(spacing: 16) {
                    header
                    sourcePreview
                    content
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
        }
        // 写入进行中不允许下滑关闭：避免写到一半界面消失（进度仍在灵动岛可见）
        .interactiveDismissDisabled(isRunning)
        // 快捷指令「随机卡面」：自动选卡 → 开始写入 → 退回后台（写入靠 BackgroundKeeper 续命）
        .task {
            guard context.autoStart, !didAutoStart else { return }
            didAutoStart = true
            // 没识别到卡就交还给用户手动选，不强行后台
            guard !model.walletCards.isEmpty else { return }
            model.selectAllWalletCards(true)
            Task { await runWrite() }
            // 等进入「进行中」阶段再退回后台，灵动岛进度才能在后台继续走
            for _ in 0..<60 {
                if case .running = phase { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            backgroundApp()
        }
    }

    /// 把 App 退到后台（私有 API，仅侧载/自签可用；App Store 构建不要用）
    private func backgroundApp() {
        UIApplication.shared.perform(Selector(("suspend")))
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    // MARK: 头部

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("写入卡面").font(.headline).foregroundColor(.primary)
                Text(context.sourceTitle).font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            // 不设关闭按钮：面板以 .sheet 呈现，下滑即可退出；
            // 写入完成后另有「完成」按钮。
        }
    }

    private var sourcePreview: some View {
        Image(uiImage: context.image)
            .resizable().aspectRatio(contentMode: .fill)
            .frame(height: 110)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Group {
                    if let author = context.sourceAuthor {
                        Text("原作者：\(author)")
                            .font(.system(size: 9))
                    } else {
                        Text("自制卡面").font(.system(size: 9))
                    }
                }
                .foregroundColor(.white)
                .padding(6)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
            )
    }

    // MARK: 内容（按阶段切换）

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .prepare:  prepareContent
        case .running:  runningContent
        case .done(let success, let failed):
            doneContent(success: success, failed: failed)
        }
    }

    // 准备阶段：识别卡 + 目标选择

    private var prepareContent: some View {
        VStack(spacing: 12) {
            // 扫描控制（不再显示「全选」按钮，避免与单卡 / 多卡选择语义冲突）
            GlassButton(title: model.isScanning ? "停止识别" : "识别我的卡片",
                        systemImage: model.isScanning ? "stop.fill" : "wave.3.right",
                        style: model.isScanning ? .secondary : .primary,
                        fullWidth: true) {
                if model.isScanning { model.stopScanning() }
                else { model.startScanning() }
            }

            if !model.scanStatus.isEmpty {
                Text(model.scanStatus)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if model.walletCards.isEmpty {
                emptyTargets
            } else {
                targetsList
            }

            let targets = model.walletCards.filter(\.isSelected)
            GlassButton(title: targets.count > 1 ? "写入全部 \(targets.count) 张卡" : "写入这张卡",
                        systemImage: "bolt.fill",
                        fullWidth: true,
                        enabled: !targets.isEmpty) {
                Task { await runWrite() }
            }
        }
    }

    private var emptyTargets: some View {
        VStack(spacing: 6) {
            Image(systemName: "creditcard.trianglebadge.exclamationmark")
                .font(.title2)
            Text("还没有识别到卡片。连按两次侧边键呼出 Apple Pay，点一下要写入的卡。")
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .foregroundColor(.secondary)
        .padding(.vertical, 18)
    }

    private var targetsList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach($model.walletCards) { $card in
                    HStack(spacing: 10) {
                        Image(systemName: card.isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(card.isSelected ? .green : .secondary.opacity(0.5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(card.title).font(.caption.weight(.medium))
                            Text(String(card.id.prefix(16)) + "…")
                                .font(.system(size: 8)).monospaced()
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(GlassContainer(tier: .thin, cornerRadius: 12) { Color.clear })
                    .onTapGesture {
                        card.isSelected.toggle()
                    }
                }
            }
        }
        .frame(maxHeight: 180)
    }

    // 进行中：玻璃形变进度

    private var runningContent: some View {
        VStack(spacing: 16) {
            ZStack {
                // 底圈
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 6)
                // 进度弧（渐变描边 + 旋转）
                Circle()
                    .trim(from: 0, to: max(Double(progressModel.percent) / 100, 0.02))
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [Color.accentColor,
                                                        Color.accentColor.opacity(0.25)]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .rotationEffect(.degrees(spinnerAngle))
                    .onAppear {
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            spinnerAngle = 360
                        }
                    }
                // 中心进度文字
                VStack(spacing: 2) {
                    Text("\(progressModel.percent)%")
                        .font(.headline.bold().monospacedDigit())
                        // 数字用等宽 + 固定内容过渡，避免逐帧闪动
                        .contentTransition(.numericText())
                    Text(progressModel.stage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                }
            }
            .frame(width: 132, height: 132)
            .padding(.vertical, 4)

            if totalCount > 1 {
                Text("第 \(min(doneCount + 1, totalCount))/\(totalCount) 张" +
                     (failedCount > 0 ? " · 失败 \(failedCount)" : ""))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            // 保活提示：告诉用户可以放心切后台
            Label("可切到后台，写入会继续", systemImage: "arrow.up.forward.app")
                .font(.caption2)
                .foregroundColor(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(liveLogs, id: \.self) { line in
                        Text(line).font(.system(size: 10)).foregroundColor(.primary.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
        }
    }

    // 完成：成败汇总，错误分别落 UI

    private func doneContent(success: Int, failed: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: failed == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(failed == 0 ? .green : .orange)
            Text(failed == 0 ? "全部卡面写入成功" : "成功 \(success) 张，失败 \(failed) 张")
                .font(.headline).foregroundColor(.primary)
            Text("强退钱包 App（App 切换器里划掉）后重新打开，即可看到新卡面。")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if !errors.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(errors, id: \.cardId) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.kind.icon)
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.kind.userMessage)
                                    .font(.caption)
                                Text(String(item.cardId.prefix(16)) + "…")
                                    .font(.system(size: 8)).monospaced()
                                    .foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(.primary)
                        .padding(10)
                        .background(GlassContainer(tier: .thin, cornerRadius: 12) { Color.clear })
                    }
                }
            }

            HStack {
                GlassButton(title: "查看写入日志", style: .secondary) { showLogs = true }
                GlassButton(title: "完成") { dismiss() }
            }
        }
        .sheet(isPresented: $showLogs) {
            WriteLogSheet()
                .presentationBackground(.clear)
        }
    }

    // MARK: 执行写入
    //
    // 三件事一起做：
    //   ① 进度：WriteEngine 从 Rust 日志解析出**真实**文件级进度 → WriteProgressModel 平滑成 1% 递增
    //   ② 后台：BackgroundWriteKeeper 保活（beginBackgroundTask + 静音音频），切后台不中断
    //   ③ 灵动岛：WriteActivityController 把百分比同步到实时活动

    private func runWrite() async {
        let targets = model.walletCards.filter(\.isSelected)
        guard !targets.isEmpty else { return }

        withAnimation(.spring(response: GlassTheme.morphResponse,
                              dampingFraction: GlassTheme.morphDamping)) {
            phase = .running
        }
        liveLogs.removeAll()
        errors.removeAll()

        totalCount = targets.count
        doneCount = 0
        failedCount = 0

        // ② 保活：从这一刻起，切到后台也会继续写
        BackgroundKeeper.shared.begin(reason: "card-write")

        // ③ 实时活动：先在灵动岛占位，随后由进度回调刷新
        WriteActivityController.shared.start(cardLabel: targets.first?.title ?? "卡面",
                                             total: targets.count)

        // ① 进度显示层
        progressModel.begin { percent, stage in
            WriteActivityController.shared.update(percent: percent, stage: stage)
        }
        progressModel.setTarget(0, stage: "准备中…")

        let items = targets.map { (cardId: $0.id, label: $0.title, image: context.image) }

        let results = await WriteEngine.shared.batchWrite(
            items: items,
            onLog: { line in
                // 回调来自后台线程，必须回主线程改 @State
                Task { @MainActor in liveLogs.append(line) }
            },
            onProgress: { p in
                Task { @MainActor in
                    doneCount = p.done
                    failedCount = p.failed
                    WriteActivityController.shared.setContext(
                        cardLabel: p.cardLabel, done: p.done, failed: p.failed, total: p.total)
                    progressModel.setTarget(p.fraction, stage: p.stage)
                }
            }
        )

        let failedItems = results.filter { $0.error != nil }
        errors = failedItems.map { (cardId: $0.cardId, kind: $0.error!) }

        // 让显示值真正走满 100%，再收尾（否则会停在半路）
        progressModel.finish(stage: failedItems.isEmpty ? "写入完成" : "写入结束")
        await progressModel.waitUntilComplete()

        WriteActivityController.shared.end(success: results.count - failedItems.count,
                                           failed: failedItems.count)
        BackgroundKeeper.shared.end()

        withAnimation(.spring(response: GlassTheme.morphResponse,
                              dampingFraction: GlassTheme.morphDamping)) {
            phase = .done(success: results.count - failedItems.count,
                          failed: failedItems.count)
        }
        // 快捷指令触发的自动写入：写完后清掉上下文，避免下次打开 App 又弹出这张已完成的结果
        if context.autoStart { model.writeContext = nil }
        model.refreshLogs()
    }
}

// MARK: - 写入日志查看

struct WriteLogSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            GlassContainer(tier: .thick, cornerRadius: 30) {
                VStack(spacing: 12) {
                    HStack {
                        Text("写入日志").font(.headline).foregroundColor(.primary)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.writeLogs) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.time.formatted(date: .abbreviated, time: .standard))
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    HStack(alignment: .top, spacing: 5) {
                                        if let kind = entry.errorKind {
                                            Image(systemName: WriteErrorKind(rawValue: kind)?.icon ?? "info.circle")
                                                .font(.system(size: 10))
                                                .foregroundColor(.orange)
                                        }
                                        Text(entry.message).font(.caption)
                                    }
                                    .foregroundColor(.primary)
                                }
                                .padding(10)
                                .background(GlassContainer(tier: .thin, cornerRadius: 10) { Color.clear })
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .onAppear { model.refreshLogs() }
    }
}
