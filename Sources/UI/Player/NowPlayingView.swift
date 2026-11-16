import SwiftUI

/// 播放页（R5、R5b）。手机和外屏是从迷你条上拉出的整页 sheet；内屏横放是整页覆盖，左右拆：
/// 左边播放器，右边歌词常开（点队列按钮时换成「接下来播放」）；内屏竖放上下拆（画面在上，控制在下）。
/// 布局只用系统容器和自定义 Layout，不写死设备尺寸，按 `adaptiveLayout` 和可用宽度排
struct NowPlayingView: View {
    @Environment(PlayerService.self) private var player
    @Environment(PlaylistStore.self) private var playlists
    @Environment(LyricOffsetStore.self) private var lyricOffsets
    @Environment(\.dismiss) private var dismiss
    @Environment(\.adaptiveLayout) private var layout

    /// 「加到歌单」「前往所在文件夹」由别的线程接上；为 nil 时对应菜单项置灰
    var onAddToPlaylist: ((Track) -> Void)?
    var onShowInFolder: ((Track) -> Void)?
    /// 从完整播放条的「队列」按钮进来时，右边直接是队列
    var startWithQueue = false

    @State private var showQueue = false
    @State private var showFullScreen = false
    @State private var showLyrics = false
    /// 同名 .lrc 的解析结果（只含文件自带的 offset，不含用户的微调）
    @State private var loadedLyrics: [LyricLine] = []
    @State private var showLyricTiming = false
    /// 标签里的词曲作者，没有为 nil
    @State private var credits: String?
    @State private var notice: String?
    /// 唱片转角。这里只持有、不读它的值（见 `VinylSpin`），转角变化不会让整页重算
    @State private var vinylSpin = VinylSpin()

    /// 内屏横放：右边常驻歌词 / 队列，不用弹层
    private var isSplit: Bool { layout == .wideLandscape }

    /// 页面上所有用到歌词的地方（歌词页、歌词条、点行跳转、时间戳）都读这一份：
    /// 把用户对这首歌的微调直接施加到行时间上，下游一律不用再各算各的
    private var lyrics: [LyricLine] {
        guard let path = player.currentTrack?.path else { return loadedLyrics }
        return Lyrics.shifted(loadedLyrics, by: Double(lyricOffsets.offsetMs(for: path)) / 1000)
    }

    /// 歌词翻开且真有歌词时才算歌词模式（只用于单栏）；翻着歌词切到没歌词的下一首会自动落回封面，
    /// 靠的是这里的 `!lyrics.isEmpty`，不必也不该去重置 showLyrics
    private var lyricsMode: Bool { showLyrics && !lyrics.isEmpty }

    var body: some View {
        // 背景走 .background(...ignoresSafeArea())，不要写成 ZStack 的兄弟层：
        // 那样整个布局容器会跟着撑出 sheet 边界，末尾的按钮画得出来却收不到点击
        Group {
            if let track = player.currentTrack {
                if isSplit {
                    splitBody(track)
                } else {
                    columnBody(track)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        // 内屏横放时队列在右栏里，不弹层；其余排法照旧弹 sheet
        .sheet(isPresented: Binding(get: { showQueue && !isSplit }, set: { showQueue = $0 })) {
            QueueSheet().environment(player)
        }
        // 弹出层是独立的环境树分支，显式注入
        .sheet(isPresented: $showLyricTiming) {
            if let track = player.currentTrack {
                LyricTimingSheet(track: track).environment(lyricOffsets)
            }
        }
        // 外屏打开播放页后状态栏的时间不见了：显式要回状态栏和系统覆盖层（主页指示条），
        // 全屏视频那页自己另有 statusBarHidden，不受影响
        .statusBarHidden(false)
        .persistentSystemOverlays(.automatic)
        .onAppear { if startWithQueue { showQueue = true } }
        // 内屏右栏开着队列时折回外屏：showQueue 还是 true，单栏会立刻把队列当 sheet 弹出来盖住播放页。
        // 换排法时收起队列，回到各自的默认（单栏看封面、左右拆看歌词）
        .onChange(of: isSplit) { _, _ in showQueue = false }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenVideo(isWide: (player.currentTrack?.videoAspect ?? 16.0 / 9.0) >= 1)
                .environment(player)
        }
        .alert("提示", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
        .onChange(of: player.errorMessage) { _, message in
            guard let message else { return }
            notice = message
            player.dismissError()
        }
        // 切歌或重新进入播放页都重读：在「文件」App 里改完歌词回来能拿到新的那份。
        // .task(id:) 在切歌时自动取消上一次的等待（歌词文件可能还在下载）
        .task(id: player.currentTrack?.path) {
            loadedLyrics = []
            guard let track = player.currentTrack else { return }
            loadedLyrics = await Lyrics.load(for: track.url)
        }
        // 词曲：没下载的歌不读标签，等下载完（downloadingPath 变 nil）再读一次
        .task(id: CreditsKey(path: player.currentTrack?.path, downloading: player.downloadingPath != nil)) {
            credits = nil
            guard let track = player.currentTrack, player.downloadingPath == nil else { return }
            credits = await TrackCredits.load(for: track)
        }
        // 停在播放页看着，就别自动锁屏。跟睡眠定时不冲突：
        // 定时到点会暂停，isPlaying 转 false，这里跟着放开，屏幕照常熄
        .onChange(of: player.isPlaying, initial: true) { _, playing in
            UIApplication.shared.isIdleTimerDisabled = playing
        }
        // 只在这一页生效，离开就交还给系统。不还的话退到列表页也不熄屏
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private struct CreditsKey: Hashable {
        let path: String?
        let downloading: Bool
    }

    // MARK: - 排法

    /// 单栏（手机、外屏、内屏竖放）。歌词翻开时替换封面和标题，进度和控制不动
    private func columnBody(_ track: Track) -> some View {
        VStack(spacing: 0) {
            if lyricsMode {
                // MV 翻到这一面时画面撤下，但 AVPlayer 归 PlayerService 持有、
                // 不随视图销毁，声音照放——等于顺手切成了「只听声音」
                LiveLyricsView(lines: lyrics, header: lyricsHeader(for: track))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 点歌词空白处翻回封面；行里的播放键是 Button，优先级高于这层手势
                .contentShape(.rect)
                .onTapGesture { showLyrics = false }
                lowerControls(for: track)
            } else {
                playerGroup(for: track)
            }
        }
        // 内屏竖放比手机宽得多，控制行摊太开不好点也不好看：收到手机级别的宽度居中
        .frame(maxWidth: layout == .compact ? .infinity : 560)
        .padding(.horizontal, 30)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    /// 内屏横放（R5b）：左播放器、右歌词或队列。左栏按比例给宽并夹住：
    /// MV 要放得下约 430pt 宽的画面，又不能把右边歌词挤没
    private func splitBody(_ track: Track) -> some View {
        GeometryReader { proxy in
            let leftWidth = min(max(proxy.size.width * 0.55, 400), 520)
            HStack(spacing: 0) {
                playerGroup(for: track)
                    .padding(.horizontal, 30)
                    // 上下都留白：整页覆盖没有 sheet 的顶边，画面不能贴着屏幕上沿
                    .padding(.vertical, 24)
                    .frame(width: leftWidth)
                rightPanel(for: track)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func rightPanel(for track: Track) -> some View {
        if showQueue {
            QueuePanel()
        } else if lyrics.isEmpty {
            Text("暂无歌词")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
        } else {
            LiveLyricsView(lines: lyrics, header: lyricsHeader(for: track))
        }
    }

    /// 画面 + 标题 + 进度 + 控制 + 底排这一组，整组在纵向上居中（空间紧时画面缩小）
    private func playerGroup(for track: Track) -> some View {
        PlayerGroupLayout {
            media(for: track)
                .padding(.top, 8)
            VStack(spacing: 0) {
                meta(for: track)
                lowerControls(for: track)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lowerControls(for track: Track) -> some View {
        VStack(spacing: 0) {
            PlayerProgressSection()
            controls(for: track)
                .padding(.top, 22)
            bottomBar(for: track)
                .padding(.top, 22)
        }
    }

    // MARK: - 封面 / 视频

    @ViewBuilder
    private func media(for track: Track) -> some View {
        if track.hasVideo {
            videoBox(for: track)
        } else {
            SpinningVinyl(track: track, spin: vinylSpin)
                // 上限 280，别在 iPad / 大窗口里无限放大；手机上由可用宽度决定。
                // 内屏横放的左栏又高又宽，不收的话唱片会顶满整栏、贴着屏幕上沿；
                // 内屏是小封面 + 整组居中，所以这里再收一档
                .frame(maxWidth: isSplit ? 240 : 280, maxHeight: isSplit ? 240 : .infinity)
                // 点唱片翻歌词（网易云那套），按钮是第二入口
                .onTapGesture {
                    if isSplit { showQueue = false } else if !lyrics.isEmpty { showLyrics = true }
                }
        }
    }

    /// MV：封面位置换成视频画面，右下角全屏。
    /// 宽高比取文件的，没读到按 16:9；竖版视频在弹性空间里按比例缩进去，
    /// 不写死高度，免得 9:16 的画面把下面的控制条顶出屏幕
    private func videoBox(for track: Track) -> some View {
        let aspect = track.videoAspect ?? 16.0 / 9.0
        return VideoSurface(player: player.av)
            .aspectRatio(aspect, contentMode: .fit)
            // 圆角由 VideoSurface 的图层自己做，这里只补一层同形状的黑底。
            // 填充形状是普通绘制，不像遮罩那样每帧离屏
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black))
            .overlay(alignment: .topLeading) {
                Text("MV")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                Button { showFullScreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("全屏")
            }
            .frame(maxWidth: 560)
    }

    // MARK: - 标题

    private func meta(for track: Track) -> some View {
        VStack(spacing: 10) {
            Text(track.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            // 先显示艺人；没有艺人才退到词曲，两样都没有就整行不显示
            if let artist = track.artist, !artist.isEmpty {
                Text(artist)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            } else if let credits {
                Text("词曲：\(credits)")
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
            }
            // 内屏横放右边本来就常开歌词，不再重复这一行
            if !isSplit { CurrentLyricStrip(lyrics: lyrics) { showLyrics = true } }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.bottom, 22)
    }

    private func lyricsHeader(for track: Track) -> [String] {
        var lines = ["《\(track.title)》"]
        if let credits { lines.append("词曲：\(credits)") }
        return lines
    }

    // MARK: - 控制

    private func controls(for track: Track) -> some View {
        HStack {
            lyricsButton
            Spacer(minLength: 0)
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.text)
                    .tappable(48)
            }
            .accessibilityLabel("上一首")
            Spacer(minLength: 0)
            Button { player.togglePlayPause() } label: {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 78, height: 78)
                    .overlay {
                        if player.downloadingPath == track.path {
                            // 没下载的歌：转圈，点一下取消
                            ProgressView().tint(Theme.onAccent).controlSize(.large)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(Theme.onAccent)
                        }
                    }
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            Spacer(minLength: 0)
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.text)
                    .tappable(48)
            }
            .accessibilityLabel("下一首")
            Spacer(minLength: 0)
            Button { player.cycleMode() } label: {
                Image(systemName: player.mode.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                    .tappable(40)
            }
            .accessibilityLabel("播放模式")
            .accessibilityValue(player.mode.label)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    /// 没歌词就置灰不可点，但位置占着：直接抽掉的话这一行会收缩，播放键跟着往左挪，就不在正中了。
    /// 实心 = 歌词正显示着：单栏是翻开了歌词，内屏横放是右边没被队列占着
    private var lyricsButton: some View {
        let active = isSplit ? (!showQueue && !lyrics.isEmpty) : lyricsMode
        return Button {
            if isSplit { showQueue = false } else { showLyrics.toggle() }
        } label: {
            Image(systemName: "quote.bubble")
                .font(.system(size: 20))
                .foregroundStyle(active ? Theme.onAccent : Theme.accent)
                .frame(width: 40, height: 40)
                .background(active ? Theme.accent : .clear, in: Circle())
                .tappable(44)
        }
        .disabled(lyrics.isEmpty)
        .opacity(lyrics.isEmpty ? 0.35 : 1)
        .accessibilityLabel("歌词")
    }

    // MARK: - 底排

    private func bottomBar(for track: Track) -> some View {
        let loved = playlists.isFavorite(track.path)
        return HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .tappable()
            }
            .accessibilityLabel("收起")
            Spacer()
            Button { toggleFavorite(track) } label: {
                Image(systemName: loved ? "heart.fill" : "heart")
                    .font(.system(size: 22))
                    .foregroundStyle(loved ? Theme.accent : Theme.secondary)
                    .tappable()
            }
            .accessibilityLabel(loved ? "取消最爱" : "加入最爱")
            Spacer()
            TrackMoreMenu(
                track: track,
                onAddToPlaylist: onAddToPlaylist,
                onShowInFolder: onShowInFolder,
                willShowInFolder: { dismiss() },
                // 没歌词就没东西可调，菜单里不出现这一项
                onAdjustLyrics: lyrics.isEmpty ? nil : { showLyricTiming = true }
            )
            Spacer()
            Button { showQueue.toggle() } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 22))
                    .foregroundStyle(showQueue ? Theme.accent : Theme.secondary)
                    .frame(width: 40, height: 40)
                    .background(showQueue ? Theme.accent.opacity(0.15) : .clear, in: Circle())
                    .tappable()
            }
            .accessibilityLabel("播放队列")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    private func toggleFavorite(_ track: Track) {
        do {
            try playlists.toggleFavorite(track.path)
        } catch {
            switch error {
            case .stillSyncing: notice = "歌单还在同步，稍后再试"
            case .readOnly: notice = "歌单文件来自更新版本的卡皮音乐，现在只能查看，不能修改"
            // 其余（还没准备好、文件解不开、写盘失败）对「点一下最爱」来说都是同一句话；
            // 用 default 而不逐个列：歌单那边再加错误类型时这里不用跟着改
            default: notice = "暂时无法修改最爱，稍后再试"
            }
        }
    }
}
