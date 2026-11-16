import SwiftUI

/// 播放页底排和完整播放条共用的「⋯」菜单（X5）：加到歌单、睡眠定时（X6）、前往所在文件夹。
/// 抽出来是因为内屏横放时迷你条换成完整播放条，菜单要在两处出现，行为必须一致
struct TrackMoreMenu: View {
    @Environment(PlayerService.self) private var player

    let track: Track
    /// 为 nil 时对应菜单项置灰
    var onAddToPlaylist: ((Track) -> Void)?
    var onShowInFolder: ((Track) -> Void)?
    /// 点「前往所在文件夹」时先做的事：播放页要先收起，不然跳转发生在页面背后
    var willShowInFolder: (() -> Void)?
    /// 为 nil 时不显示这一项：只有播放页（有歌词、有地方弹调整面板）才传
    var onAdjustLyrics: (() -> Void)?
    var iconSize: CGFloat = 22
    /// 已设睡眠定时时图标变强调色，提示还有个定时在跑
    var idleTint: Color = Theme.secondary

    var body: some View {
        Menu {
            Button { onAddToPlaylist?(track) } label: {
                Label("加到歌单", systemImage: "text.badge.plus")
            }
            .disabled(onAddToPlaylist == nil)

            sleepMenu

            if let onAdjustLyrics {
                Button { onAdjustLyrics() } label: {
                    Label("调整歌词时间", systemImage: "slider.horizontal.3")
                }
            }

            Button {
                willShowInFolder?()
                onShowInFolder?(track)
            } label: {
                Label("前往所在文件夹", systemImage: "folder")
            }
            .disabled(onShowInFolder == nil)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: iconSize))
                .foregroundStyle(player.sleepTimer == .off ? idleTint : Theme.accent)
                .tappable()
        }
        .accessibilityLabel("更多")
    }

    /// X6：睡眠定时。当前选项打勾，按分钟计时的在标题里带剩余时间
    private var sleepMenu: some View {
        Menu {
            Section(sleepStatus) {
                Picker("睡眠定时", selection: Binding(get: { player.sleepTimer }, set: { player.sleep($0) })) {
                    ForEach([15, 30, 45, 60], id: \.self) { Text("\($0) 分钟").tag(SleepTimer.minutes($0)) }
                    Text("播完这首").tag(SleepTimer.endOfTrack)
                }
                .pickerStyle(.inline)
            }
            Button(role: .destructive) { player.sleep(.off) } label: {
                Label("关闭定时", systemImage: "xmark")
            }
            .disabled(player.sleepTimer == .off)
        } label: {
            Label("睡眠定时", systemImage: "clock")
        }
    }

    private var sleepStatus: String {
        switch player.sleepTimer {
        case .off: "未开启"
        case .endOfTrack: "播完这首后暂停"
        case .minutes: "剩 " + formatTime(player.sleepRemaining ?? 0)
        }
    }
}
