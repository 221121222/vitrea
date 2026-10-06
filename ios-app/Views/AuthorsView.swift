//
//  AuthorsView.swift
//  Vitrea
//
//  作者页：顶部是交流群入口，下面才是矜火（构想与 Bug 修复）/ Lucky（制作与构建）。
//  仅通过底栏 Tab 进入。
//

import SwiftUI

struct AuthorsView: View {

    private static let qq = "3568798288"

    /// Vitrea 交流群（QQ 群 862491980）的分享链接。
    /// 打开后 QQ 的 H5 页面会引导进群；没装 QQ 会落到浏览器。
    private static let communityURL =
        "https://qun.qq.com/universal-share/share?ac=1"
        + "&authKey=lZCIe7g%2B8640MKOem%2FqX94jFSg4KX%2BM9tzZCE5Pz7Cyd4Jzt7LkUXvfANziZFrKq"
        + "&busi_data=eyJncm91cENvZGUiOiI4NjI0OTE5ODAiLCJ0b2tlbiI6ImRsSUFleXI5dWFpWGJ5RG82dWlIUVpmSVNQeFdRa3ZIV3dMbHkvNVJVVUtHVU1PamtSSE4vV3hFdERucHpQWk8iLCJ1aW4iOiIzNTY4Nzk4Mjg4In0%3D"
        + "&data=d_4koFsDWx0yMkCvQrNRFT_oZE1JO-MBFoJY8JfBDgtOLjwSsjRdKz9_uMXXdiCuEZfby1mDSe8Iy24P0CaceQ"
        + "&svctype=4&tempid=h5_group_info"

    /// 群号（从上面的 busi_data 解出来的，写死一份便于用户手动搜索）
    private static let communityGroupCode = "862491980"

    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // 交流群放在最上方
                    communityEntry

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

    // MARK: 交流群入口

    private var communityEntry: some View {
        Button {
            guard let url = URL(string: Self.communityURL) else { return }
            openURL(url)
        } label: {
            // 直接用 QQ 群分享图作入口，更直观
            Image("CommunityBanner")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .trailing) {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.black.opacity(0.32)))
                        .padding(10)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("加入 Vitrea 交流群，QQ 群 \(Self.communityGroupCode)")
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
            // 「壁纸库」声明已在 v1.3.0 移除壁纸功能时一并删除
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
