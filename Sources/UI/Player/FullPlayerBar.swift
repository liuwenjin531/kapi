import SwiftUI

/// 完整播放条：内屏横放时代替迷你条，放在 `tabViewBottomAccessory` 里。
/// 随机、上一首、播放 / 暂停、下一首、循环 | 封面 + 歌名 + 歌手 | ⋯、歌词、队列。
/// 点封面 / 歌名区域打开播放页；歌词、队列两个按钮打开播放页并让右边直接显示对应内容
struct FullPlayerBar: View {
    @Environment(PlayerService.self) private var player

    /// 打开播放页；参数 true 表示右边直接显示队列
    let onOpen: (_ queue: Bool) -> Void
    var onAddToPlaylist: ((Track) -> Void)?
    var onShowInFolder: ((Track) -> Void)?

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: 4) {
                // 随机 / 循环在播放器里是同一个三态模式的两头：各自点一下进出，互斥
                modeButton("shuffle", on: player.mode == .shuffle, label: "随机") {
                    player.mode = player.mode == .shuffle ? .sequential : .shuffle
                }
                button("backward.fill", label: "上一首") { player.previous() }
                playButton(track)
                button("forward.fill", label: "下一首") { player.next() }
                modeButton(player.mode == .repeatOne ? "repeat.1" : "repeat",
                           on: player.mode == .repeatOne, label: "单曲循环") {
                    player.mode = player.mode == .repeatOne ? .sequential : .repeatOne
                }

                Button { onOpen(false) } label: {
                    HStack(spacing: 10) {
                        PlayerArtwork(track: track, maxPixel: 120, corner: 6)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            if let artist = track.artist, !artist.isEmpty {
                                Text(artist)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开播放页：\(track.title)")

                TrackMoreMenu(
                    track: track,
                    onAddToPlaylist: onAddToPlaylist,
                    onShowInFolder: onShowInFolder,
                    iconSize: 18
                )
                button("quote.bubble", label: "歌词") { onOpen(false) }
                button("list.bullet", label: "播放队列") { onOpen(true) }
            }
            .padding(.horizontal, 12)
        }
    }

    private func button(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.text)
                .tappable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func modeButton(_ icon: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(on ? Theme.accent : Theme.secondary)
                .tappable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "开" : "关")
    }

    private func playButton(_ track: Track) -> some View {
        Button { player.togglePlayPause() } label: {
            Group {
                if player.downloadingPath == track.path {
                    ProgressView()
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                }
            }
            .foregroundStyle(Theme.text)
            .tappable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
    }
}
