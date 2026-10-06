//
//  CleanerView.swift
//  Vitrea
//
//  清理页 —— 交互模型参照 ThreeOneOSFive（3105）的 Cleaner：
//  扫描 → 按体积排序 → 多选 → 二次确认 → 清理 → 结果反馈。
//  作用域收在 Vitrea 自己的沙盒内（Caches / tmp 的可再生数据），
//  不触碰 Documents、偏好设置与写入日志。
//
//  扫描状态放在 `CleanerStore`（单例）里，视图重建不会丢 —— 切范围 / 切 Tab /
//  返回都不会重新扫描，只有右上角的刷新按钮会。
//

import SwiftUI

/// 清理范围：本应用沙盒内 / 设备上其他应用容器（沙盒外）
enum CleanerScope: String, CaseIterable, Identifiable {
    case local, device

    var id: String { rawValue }
}

struct CleanerView: View {

    @StateObject private var store = CleanerStore.shared

    @State private var scope: CleanerScope = .local
    @State private var selectedIDs: Set<String> = []
    @State private var searchText = ""
    @State private var isCleaning = false
    @State private var activeAlert: CleanerAlert?

    // MARK: 派生状态

    private var filteredRecords: [CleanerRecord] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.localRecords }
        return store.localRecords.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleIDs: [String] { filteredRecords.map(\.id) }

    private var areAllVisibleSelected: Bool {
        !visibleIDs.isEmpty && visibleIDs.allSatisfy { selectedIDs.contains($0) }
    }

    private var selectedBytes: Int64 {
        store.localRecords.reduce(0) { $0 + (selectedIDs.contains($1.id) ? $1.usage.bytes : 0) }
    }

    private var isBusy: Bool { store.isBusy || isCleaning }

    // MARK: 界面

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                scopePicker
                if scope == .local { localContent } else { DeviceCleanerView() }
            }
            .navigationTitle("清理")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 范围切换

    private var scopePicker: some View {
        Picker("范围", selection: $scope) {
            Text("本应用").tag(CleanerScope.local)
            Text("其他应用").tag(CleanerScope.device)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var localContent: some View {
        ScrollView {
            VStack(spacing: 14) {
                summaryCard
                searchBar

                if store.isScanningLocal && store.localRecords.isEmpty {
                    scanningState
                } else if store.localRecords.isEmpty {
                    emptyState
                } else {
                    itemList
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
        .onAppear { store.loadLocalIfNeeded() }
    }

    // MARK: 汇总卡

    private var summaryCard: some View {
        GlassCard(padding: 16, cornerRadius: 20) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label("可清理", systemImage: "internaldrive.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(CleanerStore.sizeText(store.localTotalBytes))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundColor(.primary)
                }

                GlassHairline()

                HStack(alignment: .firstTextBaseline) {
                    Text("已选择 \(selectedIDs.count) 项 · \(CleanerStore.sizeText(selectedBytes))")
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
                    Text(store.isScanningLocal ? "正在扫描，出结果后勾选要清理的项目"
                                               : "先勾选要清理的项目，按钮才会亮起")
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
            TextField("搜索清理项目", text: $searchText)
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

    private var itemList: some View {
        VStack(spacing: 10) {
            ForEach(filteredRecords) { record in
                Button { toggle(record.id) } label: {
                    itemRow(record)
                }
                .buttonStyle(.plain)
                .disabled(isCleaning)
            }

            if filteredRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2.weight(.light))
                        .foregroundColor(.secondary)
                    Text("没有匹配的项目")
                        .font(.subheadline.weight(.semibold))
                    Text("换个关键词试试，或清空搜索条件。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    private func itemRow(_ record: CleanerRecord) -> some View {
        let selected = selectedIDs.contains(record.id)

        return GlassCard(padding: 14, cornerRadius: 16) {
            HStack(spacing: 12) {
                Image(systemName: record.target.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(record.subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if record.usage.itemCount > 0 {
                        Text("\(record.usage.itemCount) 个文件")
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

    // MARK: 空态 / 扫描中

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在扫描缓存…")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
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
            Text("在 Caches 或 tmp 中未发现可移除的数据。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("重新扫描") { store.refreshLocal() }
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
            Text("只清理 App 沙盒内的 Caches 与 tmp。写入日志、偏好设置、配对记录与已写入的卡面均不受影响。")
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
            Button { store.refreshLocal() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isBusy)
            .accessibilityLabel("重新扫描")
        }
    }

    // MARK: 提示

    private func alert(for alert: CleanerAlert) -> Alert {
        switch alert {
        case .confirmation:
            return Alert(
                title: Text("删除临时数据？"),
                message: Text("Vitrea 将永久删除所选 \(selectedIDs.count) 项缓存（\(CleanerStore.sizeText(selectedBytes))）。下次浏览卡面时需要重新联网加载，速度可能变慢。此操作无法撤销。"),
                primaryButton: .destructive(Text("立即清理")) { Task { await cleanSelected() } },
                secondaryButton: .cancel(Text("取消"))
            )
        case .result(let message):
            return Alert(
                title: Text("清理完成"),
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
        let message = await store.cleanLocal(ids: selectedIDs)
        selectedIDs.removeAll()
        activeAlert = .result(message: message)
    }
}

private enum CleanerAlert: Identifiable {
    case confirmation
    case result(message: String)

    var id: String {
        switch self {
        case .confirmation:            return "confirmation"
        case .result(let message):     return "result-\(message)"
        }
    }
}
