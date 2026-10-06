//
//  WriteActivityWidget.swift
//  VitreaWidgets
//
//  写入卡面的实时活动：灵动岛（紧凑 / 最小 / 展开）+ 锁屏横幅。
//
//  灵动岛紧凑态右侧固定显示百分比，展开态给出进度条与阶段文案。
//

import ActivityKit
import SwiftUI
import WidgetKit

struct WriteActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WriteActivityAttributes.self) { context in
            // 锁屏 / 通知中心横幅
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state

            return DynamicIsland {
                // 展开态
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Image(systemName: state.finished ? "checkmark.seal.fill" : "creditcard.fill")
                            .foregroundColor(state.finished ? .green : .accentColor)
                        Text("写入卡面")
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.leading, 2)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(state.percent)%")
                        .font(.system(size: 20, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .padding(.trailing, 2)
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(state.cardLabel.isEmpty ? " " : state.cardLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressView(value: Double(state.percent), total: 100)
                            .tint(state.finished ? .green : .accentColor)

                        HStack(spacing: 6) {
                            Text(state.stage)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if state.total > 1 {
                                Text("\(state.done)/\(state.total)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            if state.failed > 0 {
                                Text("失败 \(state.failed)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: state.finished ? "checkmark.seal.fill" : "creditcard.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(state.finished ? Color.green : Color.accentColor)
            } compactTrailing: {
                // 紧凑态只放百分比。
                // 注意：这里必须用「显式字号 + 显式白色 + numericText 过渡」——
                //   · .caption2（11pt）太小，加上灵动岛本身缩放，看着发虚；
                //   · .foregroundStyle(.primary) 在灵动岛里会走 vibrancy，边缘发糊；
                //   · 不加 numericText 时系统对文本做**交叉淡入淡出**，更新稍快就糊成一团。
                Text("\(state.percent)%")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(1)
            } minimal: {
                Text("\(state.percent)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            .keylineTint(state.finished ? .green : .accentColor)
        }
    }
}

// MARK: - 锁屏横幅

private struct LockScreenView: View {
    let state: WriteActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: state.finished ? "checkmark.seal.fill" : "creditcard.fill")
                    .font(.title3)
                    .foregroundColor(state.finished ? .green : .accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("写入卡面")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(state.cardLabel.isEmpty ? state.stage : state.cardLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text("\(state.percent)%")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundColor(.primary)
            }

            ProgressView(value: Double(state.percent), total: 100)
                .tint(state.finished ? .green : .accentColor)

            HStack(spacing: 6) {
                Text(state.stage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if state.total > 1 {
                    Text("\(state.done)/\(state.total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                if state.failed > 0 {
                    Text("失败 \(state.failed)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(14)
    }
}

// MARK: - 扩展入口

@main
struct VitreaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        // 主屏幕：随机卡面
        RandomCardWidget()
        // 灵动岛 / 锁屏：写入进度
        WriteActivityWidget()
    }
}
