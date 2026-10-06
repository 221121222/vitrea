//
//  AuthorsView.swift
//  Vitrea
//
//  作者页：矜火（构想与 Bug 修复）/ Lucky（制作与构建）。
//  仅通过底栏 Tab 进入。
//

import SwiftUI

struct AuthorsView: View {
    private static let qq = "3568798288"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    HStack(spacing: 12) {
                        compactAuthorCard(
                            image: "jinhuo",
                            name: "矜火",
                            role: "构想与 Bug 修复",
                            qq: Self.qq
                        )
                        compactAuthorCard(
                            image: "lucky",
                            name: "Lucky",
                            role: "制作与构建",
                            qq: nil
                        )
                    }

                    bugContact
                    notices
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .navigationTitle("作者")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func compactAuthorCard(image: String, name: String, role: String, qq: String?) -> some View {
        GlassCard(padding: 14, cornerRadius: 18) {
            VStack(spacing: 8) {
                CreditsImage(name: image)
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))

                Text(name).font(.subheadline.bold())
                Text(role)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.blue.opacity(0.12)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let qq {
                    Button {
                        UIPasteboard.general.string = qq
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc").font(.system(size: 10))
                            Text("QQ").font(.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                } else {
                    Text(" ").font(.caption2)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var bugContact: some View {
        GlassCard(padding: 14, cornerRadius: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "ladybug.fill")
                    .font(.title3)
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("如在应用内出现 Bug，请联系作者。")
                        .font(.subheadline.weight(.semibold))
                    Text("联系 QQ：\(Self.qq)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notices: some View {
        VStack(spacing: 10) {
            noticeCard(icon: "lock.shield.fill", tint: .green,
                       title: "安全声明",
                       content: "全程不越狱、不访问 Secure Enclave、不读取或修改任何支付凭据，仅替换 Apple Wallet 的图像缓存文件。")
            noticeCard(icon: "doc.text.magnifyingglass", tint: .orange,
                       title: "免责条款",
                       content: "卡面素材版权归原作者所有；本 App 不对写入结果作任何保证，使用后果由使用者自行承担。")
            noticeCard(icon: "checkmark.seal.fill", tint: .blue,
                       title: "合规提醒",
                       content: "请在法律法规允许范围内使用；尊重他人作品版权，借用转载请保留原作者署名。")
            noticeCard(icon: "graduationcap.fill", tint: .purple,
                       title: "仅供学习",
                       content: "本软件仅供个人学习与技术交流，请勿用于商业用途或违规场景。")
            noticeCard(icon: "link.circle.fill", tint: .pink,
                       title: "素材来源",
                       content: "本应用所有卡面素材均出自于 cardart.cc 网站，如有侵权，请联系作者。")
        }
    }

    /// 四个声明栏统一宽高，避免长短不一
    private func noticeCard(icon: String, tint: Color, title: String, content: String) -> some View {
        GlassCard(padding: 14, cornerRadius: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(content)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(minHeight: 92, alignment: .top)
        }
    }
}
