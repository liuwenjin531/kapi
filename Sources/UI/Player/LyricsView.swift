import SwiftUI

/// 拖动时离正中最近的那一行。
/// ScrollPosition 的 viewID 在用户手动滚动之后会变成 nil——位置改用偏移量表示，
/// 不再是某个 id，问不出「正中是谁」。所以各行自己报到中线的距离，取最近的
private struct CenteredLine: Equatable {
    let index: Int
    let distance: CGFloat
}

private struct CenteredLineKey: PreferenceKey {
    static let defaultValue: CenteredLine? = nil
    static func reduce(value: inout CenteredLine?, nextValue: () -> CenteredLine?) {
        guard let next = nextValue() else { return }
        if let current = value, current.distance <= next.distance { return }
        value = next
    }
}

/// 歌词区，交互照着网易云那套。
/// 平时跟着播放进度滚；手指一碰就让位，此时正中那行浮出时间戳和播放键，
/// **点了才跳**——原来点哪行跳哪行，手一滑歌就跑了，没有回头余地。
/// 松手三秒没有动作再自己滚回正在唱的那句
struct LyricsView: View {
    let lines: [LyricLine]
    /// 歌词上方的几行说明（《曲名》、词曲），随歌词一起滚走，不是歌词本身
    var header: [String] = []
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void

    /// 手指接管中。滚动位置听播放进度的还是听手指的，全看它
    @State private var handedOver = false
    @State private var resume: Task<Void, Never>?
    @State private var centered: Int?

    private static let space = "lyrics"

    private var current: Int? { Lyrics.index(at: currentTime, in: lines) }

    /// 拖动时停在正中的那一行。没在拖就没有——那行底色只在拖动时出现
    private var focused: Int? { handedOver ? centered : nil }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, text in
                            Text(text)
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.secondary)
                                .multilineTextAlignment(.center)
                        }
                        if !header.isEmpty { Color.clear.frame(height: 14) }
                        ForEach(lines.indices, id: \.self) { i in
                            row(i, containerHeight: geo.size.height).id(i)
                        }
                    }
                    // 首尾各垫半屏，第一句和最后一句才能停到正中而不是贴着边
                    .padding(.vertical, max(geo.size.height / 2 - 28, 24))
                }
                .coordinateSpace(.named(Self.space))
                .animation(.easeOut(duration: 0.25), value: current)
                // 上下渐隐，视线自然收在中间。硬切的话最上最下那行像被裁断
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.16),
                        .init(color: .black, location: 0.84),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .onPreferenceChange(CenteredLineKey.self) { centered = $0?.index }
                // iOS 18 才有的滚动阶段回调。没有它就只能拿 DragGesture 手搓状态机，
                // 而手搓最容易把自己发起的滚动误判成用户插手，然后再也不跟随了
                .onScrollPhaseChange { _, phase in
                    switch phase {
                    case .idle:
                        if handedOver { scheduleResume(proxy) }
                    case .animating:
                        break  // 这是自己滚的，不算用户插手
                    default:
                        resume?.cancel()
                        handedOver = true
                    }
                }
                .onChange(of: current, initial: true) { _, index in
                    guard !handedOver else { return }
                    scroll(to: index, with: proxy)
                }
            }
        }
        .onDisappear { resume?.cancel() }
    }

    @ViewBuilder
    private func row(_ i: Int, containerHeight: CGFloat) -> some View {
        let isCurrent = i == current
        let isFocused = i == focused
        Text(lines[i].text)
            .font(.system(size: isCurrent ? 21 : 18, weight: isCurrent ? .bold : .regular))
            .foregroundStyle(isCurrent ? Theme.accent : Theme.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 6)
            // 间奏行没有字，而空 Text 的高度是零，不撑一下这份留白就白留了
            .frame(maxWidth: .infinity, minHeight: lines[i].text.isEmpty ? 22 : 0)
            .background {
                if isFocused {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card)
                }
            }
            // 只在拖动时才量：平时挂着这一堆 GeometryReader，每帧都要白算一遍
            .background {
                if handedOver {
                    GeometryReader { row in
                        Color.clear.preference(
                            key: CenteredLineKey.self,
                            value: CenteredLine(
                                index: i,
                                distance: abs(row.frame(in: .named(Self.space)).midY - containerHeight / 2)
                            )
                        )
                    }
                }
            }
            // 时间戳和播放键挂在两侧空白里，正文照旧居中，不会被挤偏
            .overlay(alignment: .leading) {
                if isFocused {
                    Text(formatTime(lines[i].time))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .padding(.leading, 12)
                }
            }
            .overlay(alignment: .trailing) {
                if isFocused {
                    Button {
                        onSeek(lines[i].time)
                        // 跳完就别再等那三秒，直接回到跟随
                        resume?.cancel()
                        handedOver = false
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }
            }
    }

    private func scheduleResume(_ proxy: ScrollViewProxy) {
        resume?.cancel()
        resume = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            handedOver = false
            scroll(to: current, with: proxy)
        }
    }

    private func scroll(to index: Int?, with proxy: ScrollViewProxy) {
        guard !lines.isEmpty else { return }
        // 前奏期间还没唱到第一句，index 是 nil。这时该回到开头，
        // 而不是赖在上一首留下的滚动位置上
        withAnimation(.easeOut(duration: 0.35)) {
            proxy.scrollTo(index ?? 0, anchor: .center)
        }
    }
}
