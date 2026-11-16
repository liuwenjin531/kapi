import SwiftUI
import UIKit

/// 首次启动、向系统要 iCloud 容器时的过渡页
struct PreparingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("正在准备乐库…")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

/// iCloud 不可用的报错页。没登录、关了 iCloud 云盘、关了本 App 的 iCloud 都落到这里；
/// 用户去设置里改完回到 App，`LibraryRoot` 会自动重试，所以这里不放「我已打开」之类的确认按钮
struct ICloudUnavailableView: View {
    /// 手动重试（部分情况下回前台通知不一定来）
    var onRetry: () -> Void
    /// 不想开 iCloud 的人（包括没登录 iCloud 的审核设备）可以直接改用本机乐库，不至于卡死在这一页
    var onUseLocal: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 56))
                .foregroundStyle(Theme.secondary)
            VStack(spacing: 8) {
                Text("无法使用 iCloud")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text("你选了把乐库放在 iCloud 云盘里。请先登录 Apple 账户，并在「设置 > Apple 账户 > iCloud」中打开「iCloud 云盘」和「卡皮音乐」；也可以改用本机存储。")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.secondary)
            }
            VStack(spacing: 12) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    // 不用 borderedProminent：它的字是白色，深色主题的强调色是柠檬绿，白字看不清
                    Text("打开设置")
                        .font(.headline)
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                Button(action: onUseLocal) {
                    Text("改用本机存储").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button("重试", action: onRetry)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

#Preview("正在准备") { PreparingView() }
#Preview("iCloud 不可用") { ICloudUnavailableView(onRetry: {}, onUseLocal: {}) }
