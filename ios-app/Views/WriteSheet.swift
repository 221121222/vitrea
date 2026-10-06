//
//  WriteSheet.swift
//  Vitrea
//
//  写入面板：选择目标卡（卡识别）→ 单卡 / 批量写入 → 进度与四类错误 UI + 日志。
//

import SwiftUI

struct WriteSheet: View {
    let context: WriteContext
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Phase {
        case prepare, running, done(success: Int, failed: Int)
    }

    @State private var phase: Phase = .prepare
    @State private var progress: Double = 0
    @State private var liveLogs: [String] = []
    @State private var errors: [(cardId: String, kind: WriteErrorKind)] = []
    @State private var showLogs = false
    @State private var spinnerAngle: Double = 0

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
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).foregroundColor(.secondary)
            }
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
                    .trim(from: 0, to: max(progress, 0.02))
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
                // 中心进度文字（字号调小，便于与进度环协调）
                VStack(spacing: 2) {
                    Text("\(Int(progress * 100))%")
                        .font(.headline.bold().monospacedDigit())
                    Text("写入中…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 132, height: 132)
            .padding(.vertical, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(liveLogs, id: \.self) { line in
                        Text(line).font(.system(size: 10)).foregroundColor(.primary.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
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

    private func runWrite() async {
        let targets = model.walletCards.filter(\.isSelected)
        guard !targets.isEmpty else { return }

        withAnimation(.spring(response: GlassTheme.morphResponse,
                              dampingFraction: GlassTheme.morphDamping)) {
            phase = .running
        }
        liveLogs.removeAll()
        errors.removeAll()

        let items = targets.map { (cardId: $0.id, image: context.image) }
        let results = await WriteEngine.shared.batchWrite(
            items: items,
            onLog: { line in
                // 回调来自后台线程，必须回主线程改 @State
                Task { @MainActor in liveLogs.append(line) }
            },
            onProgress: { p, done, total in
                // 单卡时 p 未走满 1.0，按 (卡序 + 卡内进度) 归一化
                let overall = (Double(done - 1) + p) / Double(max(total, 1))
                Task { @MainActor in
                    // 平滑快速地爬升，数字按 1% 细步递进，不再大跳
                    withAnimation(.easeOut(duration: 0.18)) {
                        progress = min(max(overall, 0), 1)
                    }
                }
            }
        )

        let failedItems = results.filter { $0.error != nil }
        errors = failedItems.map { (cardId: $0.cardId, kind: $0.error!) }

        withAnimation(.spring(response: GlassTheme.morphResponse,
                              dampingFraction: GlassTheme.morphDamping)) {
            phase = .done(success: results.count - failedItems.count,
                          failed: failedItems.count)
        }
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
