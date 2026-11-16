import SwiftUI

/// 「接下来播放」弹层（手机和外屏）：队列面板套上 sheet 的背景和高度档位
struct QueueSheet: View {
    var body: some View {
        QueuePanel()
            .background(Theme.sheet.ignoresSafeArea())
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }
}

/// 「接下来播放」：当前队列，点一行跳播，长按拖动排序，左滑移出队列。
/// 单独成面板是因为内屏横放时它不弹层，而是换掉播放页右边的歌词
struct QueuePanel: View {
    @Environment(PlayerService.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("接下来播放").font(.system(size: 20, weight: .heavy))
                Text("\(player.queue.count) 首 · \(player.mode.label)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 8)

            List {
                // 用 enumerated 的下标当 id：队列里理论上不会有两份相同的 path，
                // 但「播放下一首」允许把同一首再插一次，path 当 id 会重复
                ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
                    row(track, isCurrent: index == player.currentIndex)
                        .contentShape(.rect)
                        .onTapGesture { player.jump(to: index) }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Theme.separator)
                }
                // 不强开 editMode，否则点击选行会顶掉「点一下跳播」
                .onMove { player.moveInQueue(from: $0, to: $1) }
                .onDelete { player.removeFromQueue(at: $0) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ track: Track, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            PlayerArtwork(track: track, maxPixel: 120, corner: 7)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    FormatPill(text: track.format)
                    if track.duration > 0 {
                        Text(formatTime(track.duration))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if player.downloadingPath == track.path {
                ProgressView().controlSize(.small)
            } else {
                // 只是提示「可拖动」，真正的拖动手势是整行长按
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(minHeight: 56)
    }
}
