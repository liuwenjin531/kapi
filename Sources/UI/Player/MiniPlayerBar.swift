import SwiftUI

/// 迷你播放条，放在 `tabViewBottomAccessory` 里：封面、歌名、播放 / 暂停、下一首。
/// 点整条（除按钮外）打开播放页；没在播放时由外层不启用 accessory，这里不管显隐
struct MiniPlayerBar: View {
    @Environment(PlayerService.self) private var player
    let onOpen: () -> Void

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: 12) {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        PlayerArtwork(track: track, maxPixel: 120, corner: 6)
                            .frame(width: 36, height: 36)
                        Text(track.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开播放页：\(track.title)")

                Button { player.togglePlayPause() } label: {
                    Group {
                        if player.downloadingPath == track.path {
                            // 等下载时转圈；点一下 = 取消
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20))
                        }
                    }
                    .foregroundStyle(Theme.text)
                    .tappable()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.text)
                        .tappable()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("下一首")
            }
            .padding(.horizontal, 16)
        }
    }
}
