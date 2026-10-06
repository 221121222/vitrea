//
//  DeviceCleanerView.swift
//  Vitrea
//
//  跨应用清理（沙盒外）：借 HouseArrest 把别的 App 容器租借出来，
//  只清理其 Library/Caches 与 tmp —— 交互沿用 3105 的模型：
//  扫描 → 按体积排序 → 多选 → 二次确认 → 清理 → 结果反馈。
//
//  范围只有「全部应用」：不再区分第三方 / 系统应用 ——
//  系统应用里真正有可清缓存的很少，多一个筛选只会让人多按一次。
//
//  前置条件：有效的本机配对 + 回环隧道（与写入一致）。
//
//  扫描状态在 `CleanerStore`（单例）里，所以离开本页再回来不会重新扫描；
//  只有右上角刷新按钮会。
//

import SwiftUI

struct DeviceCleanerView: View {

    @StateObject private var store = CleanerStore.shared

    @State private var selectedIDs: Set<String> = []
    @State private var searchText = ""
    @State private var isCleaning = false
    @State private var activeAlert: DeviceCleanerAlert?

    private var isBusy: Bool { store.isBusy || isCleaning }

    // MARK: 派生状态

    private var filteredRecords: [DeviceAppRecord] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.deviceRecords }
        return store.deviceRecords.filter {
            $0.app.displayName.localizedCaseInsensitiveContains(query)
                || $0.app.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleIDs: [String] { filteredRecords.map(\.id) }

    private var areAllVisibleSelected: Bool {
        !visibleIDs.isEmpty && visibleIDs.allSatisfy { selectedIDs.contains($0) }
    }

    private var selectedBytes: Int64 {
        store.deviceRecords.reduce(0) { $0 + (selectedIDs.contains($1.id) ? $1.usage.bytes : 0) }
    }

    // MARK: 界面

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                summaryCard
                searchBar

                if let issue = DeviceCleaner.environmentIssue() {
                    environmentNotice(issue)
                } else if store.isScanningDevice && store.deviceRecords.isEmpty {
                    scanningState
                } else if store.deviceRecords.isEmpty {
                    emptyState
                } else {
                    appList
                }

                scopeNotice
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar { toolbarContent }
        .alert(item: $activeAlert, content: alert(for:))
        // 只在首次进入时扫一次；之后只有点刷新才重新扫描
        .task { await store.loadDeviceIfNeeded() }
        .onChange(of: store.deviceError) { _, newValue in
            if let newValue { activeAlert = .failure(message: newValue) }
        }
    }

    // MARK: 汇总卡

    private var summaryCard: some View {
        GlassCard(padding: 16, cornerRadius: 20) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label("可清理", systemImage: "square.stack.3d.up.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(CleanerStore.sizeText(store.deviceTotalBytes))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundColor(.primary)
                }

                GlassHairline()

                HStack(alignment: .firstTextBaseline) {
                    Text("已选择 \(selectedIDs.count) 个应用 · \(CleanerStore.sizeText(selectedBytes))")
                        .font(.footnote.weight(.medium).monospacedDigit())
                        .foregroundColor(.secondary)
                    Spacer()
                    if isBusy {
                        ProgressView().controlSize(.small)
                    }
                }

                GlassButton(
                    title: isCleaning ? "正在清理…" : "清理 \(CleanerStore.sizeText(selectedBytes))",
                    systemImage: isCleaning ? nil : "trash",
                    style: .primary,
                    fullWidth: true,
                    enabled: !selectedIDs.isEmpty && !isBusy
                ) {
                    activeAlert = .confirmation
                }

                if !isBusy && selectedIDs.isEmpty {
                    Text(store.isScanningDevice ? "正在扫描，出结果后勾选要清理的应用"
                                                : "先勾选要清理的应用，按钮才会亮起")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("搜索应用名称或 Bundle ID", text: $searchText)
                .font(.subheadline)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 列表

    private var appList: some View {
        VStack(spacing: 10) {
            ForEach(filteredRecords) { record in
                Button { toggle(record.id) } label: {
                    appRow(record)
                }
                .buttonStyle(.plain)
                .disabled(isCleaning)
            }

            if filteredRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2.weight(.light))
                        .foregroundColor(.secondary)
                    Text("没有匹配的应用")
                        .font(.subheadline.weight(.semibold))
                    Text("换个关键词试试。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    private func appRow(_ record: DeviceAppRecord) -> some View {
        let selected = selectedIDs.contains(record.id)

        return GlassCard(padding: 14, cornerRadius: 16) {
            HStack(spacing: 12) {
                Image(systemName: "app.dashed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.app.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(record.app.bundleID)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if record.usage.items > 0 {
                        Text("\(record.usage.items) 个文件")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }

                Spacer(minLength: 6)

                Text(CleanerStore.sizeText(record.usage.bytes))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundColor(.primary)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(selected ? .accentColor : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(selected ? "已选择" : "未选择")
    }

    // MARK: 状态

    private func environmentNotice(_ issue: WriteErrorKind) -> some View {
        GlassCard(padding: 16, cornerRadius: 16) {
            VStack(spacing: 10) {
                Image(systemName: issue.icon)
                    .font(.title2)
                    .foregroundColor(.orange)
                Text("需要连接才能扫描其他应用")
                    .font(.subheadline.weight(.semibold))
                Text(issue.userMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("重新扫描") { Task { await store.refreshDevice() } }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在扫描应用缓存…")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
            if store.deviceTotal > 0 {
                Text("已扫描 \(store.deviceScanned) / \(store.deviceTotal)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Text("可切到后台，扫描会继续")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)
            Text("已经很干净")
                .font(.headline)
            Text("未发现存在可清理缓存的应用。部分应用（例如 App Store 应用）系统不允许访问其容器。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("重新扫描") { Task { await store.refreshDevice() } }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var scopeNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("有限清理", systemImage: "checkmark.shield")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
            Text("经开发者配对租借目标应用容器，只清理其中的 Library/Caches 与 tmp；Documents、偏好设置、钥匙串与账号数据一律不动。建议先关闭目标应用。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 全选 / 取消全选 —— 放在右上角，一键切换
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                toggleSelectAll()
            } label: {
                Text(areAllVisibleSelected ? "取消全选" : "全选")
                    .font(.subheadline.weight(.medium))
            }
            .disabled(visibleIDs.isEmpty || isBusy)
            .accessibilityLabel(areAllVisibleSelected ? "取消全选" : "全选")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("排序", selection: Binding(
                    get: { store.sortOrder },
                    set: { store.setSortOrder($0) })) {
                    ForEach(CleanerSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(isBusy)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await store.refreshDevice() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isBusy)
            .accessibilityLabel("重新扫描")
        }
    }

    // MARK: 提示

    private func alert(for alert: DeviceCleanerAlert) -> Alert {
        switch alert {
        case .confirmation:
            return Alert(
                title: Text("删除其他应用的临时数据？"),
                message: Text("Vitrea 将永久删除所选 \(selectedIDs.count) 个应用的 Library/Caches 与 tmp（\(CleanerStore.sizeText(selectedBytes))）。请先关闭这些应用，下次打开时重建缓存可能变慢。此操作无法撤销。"),
                primaryButton: .destructive(Text("立即清理")) { Task { await cleanSelected() } },
                secondaryButton: .cancel(Text("取消"))
            )
        case .result(let message):
            return Alert(
                title: Text("清理完成"),
                message: Text(message),
                dismissButton: .default(Text("好"))
            )
        case .failure(let message):
            return Alert(
                title: Text("无法完成清理"),
                message: Text(message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    // MARK: 动作

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func toggleSelectAll() {
        if areAllVisibleSelected {
            selectedIDs.removeAll()
        } else {
            selectedIDs.formUnion(visibleIDs)
        }
    }

    private func cleanSelected() async {
        guard !isBusy, !selectedIDs.isEmpty else { return }
        isCleaning = true
        defer { isCleaning = false }
        let message = await store.cleanDevice(ids: selectedIDs)
        selectedIDs.removeAll()
        activeAlert = .result(message: message)
    }
}

private enum DeviceCleanerAlert: Identifiable {
    case confirmation
    case result(message: String)
    case failure(message: String)

    var id: String {
        switch self {
        case .confirmation:         return "confirmation"
        case .result(let message):  return "result-\(message)"
        case .failure(let message): return "failure-\(message)"
        }
    }
}
