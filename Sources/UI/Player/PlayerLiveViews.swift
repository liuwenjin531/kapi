import SwiftUI
import Observation

// 播放页里「跟着播放进度动」的几块，各自读 `player.currentTime`。
//
// 为什么要拆出来：`PlayerService.currentTime` 播放时每 0.25 秒变一次，SwiftUI 的观察是按「谁读了它」重算的。
// 原来这几块都写在 `NowPlayingView` 里，整页（包括底排的「⋯」菜单）每秒要重算 8 次，
// 菜单的内容也跟着每 0.25 秒被重建一次；拆成各自独立的小视图后，只有这几块自己重算，
// 整页和菜单在播放时是静止的。新增依赖进度的界面，也请照这个做：读 `currentTime` 的放进独立小视图，别放回 `NowPlayingView`

/// 进度条和两端的时间。拖动中的目标时间 `scrub` 只有它自己用，所以状态也放在这里
struct PlayerProgressSection: View {
    @Environment(PlayerService.self) private var player
    /// 拖动进度条时的目标时间，松手才真的 seek
    @State private var scrub: TimeInterval?

    var body: some View {
        let shown = scrub ?? player.currentTime
        VStack(spacing: 10) {
            ScrubBar(
                time: shown,
                total: max(player.duration, 1),
                onDrag: { scrub = $0 },
                onCommit: { player.seek(to: $0); scrub = nil }
            )
            HStack {
                Text(formatTime(shown))
                Spacer()
                Text("-" + formatTime(max(0, player.duration - shown)))
            }
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(Theme.secondary)
        }
    }
}

/// 歌名下面留一行当前这句。换句时横向滑入滑出。
/// 靠 .id 换掉视图身份来触发转场——只改 Text 的文字是原地更新，不会有动画
struct CurrentLyricStrip: View {
    @Environment(PlayerService.self) private var player
    let lyrics: [LyricLine]
    let onTap: () -> Void

    var body: some View {
        if !lyrics.isEmpty {
            let index = Lyrics.index(at: player.currentTime, in: lyrics)
            ZStack {
                Text(index.map { lyrics[$0].text } ?? "")
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .id(index ?? -1)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            // 定高加裁剪：滑入的那句是从框外进来的，不裁会糊到左右两边去
            .frame(height: 20)
            .clipped()
            .animation(.easeInOut(duration: 0.3), value: index)
            .contentShape(.rect)
            .onTapGesture(perform: onTap)
        }
    }
}

/// 歌词区。`LyricsView` 要一个随进度变的 `currentTime`，这层负责去读它
struct LiveLyricsView: View {
    @Environment(PlayerService.self) private var player
    let lines: [LyricLine]
    var header: [String] = []

    var body: some View {
        LyricsView(
            lines: lines,
            header: header,
            currentTime: player.currentTime,
            onSeek: { player.seek(to: $0) }
        )
    }
}

/// 唱片的转角（一圈 12 秒）。
/// 放在一个单独的对象里而不是 `NowPlayingView` 的 `@State`：整页只持有它、不读它的值，
/// 转角每 0.25 秒变一次时只有唱片自己重算。翻到歌词面再翻回来，唱片接着上次的角度转，不会跳回 0
@Observable
@MainActor
final class VinylSpin {
    private(set) var angle: Double = 0

    /// 播放时每 0.25 秒推一次，小步用线性插值补成连续旋转；
    /// 拖动跳转、切歌归零是大步，直接换到新角度——否则几千度的差值会在 0.25 秒里转完，看起来就是闪
    func advance(by delta: TimeInterval) {
        let degrees = delta * 30
        if abs(delta) < 1 {
            withAnimation(.linear(duration: 0.25)) { angle += degrees }
        } else {
            angle += degrees
        }
    }
}

/// 会转的黑胶。转角由进度的变化量推出来（见 `VinylSpin`）
struct SpinningVinyl: View {
    @Environment(PlayerService.self) private var player
    let track: Track
    let spin: VinylSpin

    var body: some View {
        VinylDisc(track: track, angle: spin.angle)
            .onChange(of: player.currentTime) { old, new in spin.advance(by: new - old) }
    }
}
