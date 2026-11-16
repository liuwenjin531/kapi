import AppIntents
import SwiftUI
import WidgetKit

/// 按小组件尺寸和当前状态分发到具体视图，并统一铺背景、挂点击跳转
struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    private var palette: Theme.Palette { Theme.palette(entry.skin) }

    var body: some View {
        switch entry.display {
        case .idle:
            IdleView(palette: palette, family: family)
                .containerBackground(palette.bg, for: .widget)
                // 空闲态整块点击就是「播放最爱」：小号只支持一个点击目标，中号也保持一致，行为好预期
                .widgetURL(WidgetLink.playFavorites)
        case let .track(playing, playback):
            Group {
                if family == .systemSmall {
                    SmallTrackView(playing: playing, playback: playback, cover: entry.cover, palette: palette)
                } else {
                    MediumTrackView(playing: playing, playback: playback, cover: entry.cover, palette: palette)
                }
            }
            .containerBackground(for: .widget) {
                // 小号：封面铺满整个小组件；中号：封面是左边一块，背景用主题底色
                if family == .systemSmall {
                    CoverArtwork(title: playing.title, cover: entry.cover, symbolScale: 0.3)
                } else {
                    palette.bg
                }
            }
            .widgetURL(WidgetLink.player)
        }
    }
}

// MARK: - 封面

/// 有封面画封面，没有就按标题取色画个音符占位（和 App 里 `Artwork` 的占位同一套色）
struct CoverArtwork: View {
    let title: String
    let cover: UIImage?
    /// 占位音符相对边长的比例
    var symbolScale: CGFloat = 0.34

    var body: some View {
        GeometryReader { geo in
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                Theme.placeholder(for: title)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: min(geo.size.width, geo.size.height) * symbolScale))
                            .foregroundStyle(.white.opacity(0.55))
                    }
            }
        }
    }
}

// MARK: - 小号

/// 小号：封面铺满整个小组件，底部渐变压着曲名和艺人，右下角播放/暂停，最底一条进度线
private struct SmallTrackView: View {
    let playing: WidgetSnapshot.NowPlaying
    let playback: WidgetDisplay.Playback
    let cover: UIImage?
    let palette: Theme.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playing.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let artist = playing.artist {
                        Text(artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                PlayPauseButton(isPlaying: playing.isPlaying, palette: palette, side: 34, iconSize: 14)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            ProgressLine(playback: playback, tint: .white)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 底部压暗：封面可能很亮，白字得有底
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
        }
    }
}

// MARK: - 中号

private struct MediumTrackView: View {
    let playing: WidgetSnapshot.NowPlaying
    let playback: WidgetDisplay.Playback
    let cover: UIImage?
    let palette: Theme.Palette

    var body: some View {
        HStack(spacing: 14) {
            CoverArtwork(title: playing.title, cover: cover)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(playing.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                if let artist = playing.artist {
                    Text(artist)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
                Spacer(minLength: 6)
                ProgressLine(playback: playback, tint: palette.accent)
                ElapsedRow(playing: playing, playback: playback, color: palette.secondary)
                    .padding(.top, 4)
                HStack {
                    Spacer(minLength: 0)
                    Button(intent: PreviousTrackIntent()) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(palette.text)
                            .frame(width: 44, height: 40)
                    }
                    PlayPauseButton(isPlaying: playing.isPlaying, palette: palette, side: 40, iconSize: 17)
                    Button(intent: NextTrackIntent()) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(palette.text)
                            .frame(width: 44, height: 40)
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .padding(14)
    }
}

// MARK: - 共用小件

/// 播放 / 暂停圆钮。图标按「正在放」显示：放着时显示暂停键，反之亦然
private struct PlayPauseButton: View {
    let isPlaying: Bool
    let palette: Theme.Palette
    let side: CGFloat
    let iconSize: CGFloat

    var body: some View {
        Button(intent: TogglePlayPauseIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(palette.onAccent)
                .frame(width: side, height: side)
                .background(palette.accent, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// 进度线。播放中交给系统自己走（`timerInterval`），不占小组件的刷新次数；暂停时是静态的。
/// 轨道和高度全用系统的线性样式，不自己叠背景或缩放：
/// 系统的进度条在小组件里有固定的样式，叠上去的东西反而容易和它打架
private struct ProgressLine: View {
    let playback: WidgetDisplay.Playback
    let tint: Color

    var body: some View {
        Group {
            switch playback {
            case .running(let range):
                ProgressView(timerInterval: range, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            case .paused(let fraction):
                ProgressView(value: fraction)
            case .unknown:
                // 时长未知：画一条空轨，布局不跳
                ProgressView(value: 0)
            }
        }
        .progressViewStyle(.linear)
        .tint(tint)
    }
}

/// 已播时间 / 剩余时间。播放中的已播时间由系统自己走
private struct ElapsedRow: View {
    let playing: WidgetSnapshot.NowPlaying
    let playback: WidgetDisplay.Playback
    let color: Color

    var body: some View {
        HStack {
            switch playback {
            case .running(let range):
                // 带 timerInterval 的 Text 默认会撑满可用宽度，把右边的总时长挤走，所以定宽
                Text(timerInterval: range, pauseTime: nil, countsDown: false, showsHours: false)
                    .frame(width: 44, alignment: .leading)
                Spacer(minLength: 0)
                Text(Self.clock(playing.duration))
            case .paused(let fraction):
                Text(Self.clock(playing.duration * fraction))
                Spacer(minLength: 0)
                Text(Self.clock(playing.duration))
            case .unknown:
                Text("")
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(color)
        .lineLimit(1)
    }

    /// 左边已播、右边总时长。不用「剩余」：播放中剩余时间只在刷新时才更新，会和自己走的已播时间对不上
    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 空闲态

private struct IdleView: View {
    let palette: Theme.Palette
    let family: WidgetFamily

    var body: some View {
        let compact = family == .systemSmall
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: compact ? 20 : 24, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .frame(width: compact ? 44 : 52, height: compact ? 44 : 52)
                .background(palette.accent, in: Circle())
            Spacer(minLength: 0)
            Text("卡皮音乐")
                .font(.system(size: compact ? 15 : 17, weight: .semibold))
                .foregroundStyle(palette.text)
            Text("点一下播放最爱")
                .font(.system(size: compact ? 12 : 13))
                .foregroundStyle(palette.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(16)
    }
}
