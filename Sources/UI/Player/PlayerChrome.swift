import SwiftUI

/// 把迷你条和播放页挂到 TabView 上的一站式修饰器：
/// 迷你条走 iOS 26 起的 `tabViewBottomAccessory`，播放页是从迷你条上拉出的整页 sheet。
/// 放在一处，App 层只需一行，别的线程也不用知道播放页怎么弹
private struct PlayerChrome: ViewModifier {
    @Environment(PlayerService.self) private var player
    @Environment(PlaylistStore.self) private var playlists
    @Environment(LyricOffsetStore.self) private var lyricOffsets
    @Environment(AppRouter.self) private var router
    @Environment(\.artworkProvider) private var artworkProvider

    let onShowInFolder: ((Track) -> Void)?

    @Environment(\.adaptiveLayout) private var layout
    /// 隔空投送 / 分享收到的文件：「收到文件」弹层挂在 App 最外层
    @Environment(ReceivedFiles.self) private var received

    @State private var showPlayer = false
    /// 从完整播放条的队列按钮进来：播放页右边直接显示队列
    @State private var openWithQueue = false
    /// 播放页「⋯ › 加到歌单」选中的歌。
    /// 歌单选择页必须挂在播放页 sheet 里面弹：SwiftUI 同一层只能弹一个 sheet，
    /// 挂在根视图上时播放页正开着，选择页根本出不来
    @State private var trackToAdd: Track?
    /// 完整播放条「⋯ › 加到歌单」选中的歌。播放页没开时才会点到播放条，所以和上面那个分开，不会同时弹
    @State private var barTrackToAdd: Track?

    private func open(queue: Bool = false) {
        openWithQueue = queue
        showPlayer = true
    }

    /// 播放页内容。sheet 和整页覆盖共用一份
    private var playerPage: some View {
        // 弹出层是独立的环境树分支，显式注入，不指望从底下继承
        NowPlayingView(
            onAddToPlaylist: { trackToAdd = $0 },
            onShowInFolder: onShowInFolder,
            startWithQueue: openWithQueue
        )
        .sheet(item: $trackToAdd) { AddToPlaylistSheet(track: $0) }
        .environment(player)
        .environment(playlists)
        .environment(lyricOffsets)
        .environment(\.artworkProvider, artworkProvider)
        .environment(\.adaptiveLayout, layout)
    }

    func body(content: Content) -> some View {
        content
            .tabViewBottomAccessory(isEnabled: player.currentTrack != nil) {
                // 内屏横放换成完整播放条，外屏和 iPhone 保持迷你条
                if layout == .wideLandscape {
                    FullPlayerBar(onOpen: { open(queue: $0) },
                                  onAddToPlaylist: { barTrackToAdd = $0 },
                                  onShowInFolder: onShowInFolder)
                } else {
                    MiniPlayerBar { open() }
                }
            }
            .sheet(item: $barTrackToAdd) { AddToPlaylistSheet(track: $0).environment(playlists) }
            // 内屏上 sheet 是居中的小卡片，背后还留着一圈被压暗的页面，不是我们要的整页：
            // 宽布局改用整页覆盖，手机和外屏仍是上拉 sheet。
            // setter 只在用户手势收起时才会被调用（false），程序里切换布局不会误关
            .sheet(isPresented: Binding(get: { showPlayer && !layout.isWide }, set: { if !$0 { showPlayer = false } })) {
                playerPage
            }
            .fullScreenCover(isPresented: Binding(get: { showPlayer && layout.isWide }, set: { if !$0 { showPlayer = false } })) {
                playerPage
            }
            // 小组件点封面：拉起播放页。没有在放的歌就什么也不做（只是把 App 打开）
            .onChange(of: router.pendingAction, initial: true) { _, action in
                guard action == .openPlayer else { return }
                router.pendingAction = nil
                if player.currentTrack != nil { open() }
            }
            // 收到文件要弹「放到哪个文件夹」：SwiftUI 同一时间只能弹一层，播放页开着它就出不来，先收起播放页
            .onChange(of: received.isPresented) { _, presenting in
                guard presenting else { return }
                showPlayer = false
                barTrackToAdd = nil
            }
            // 队列清空、曲目被删光之后播放页没有内容可显示，收起
            .onChange(of: player.currentTrack == nil) { _, isEmpty in
                if isEmpty { showPlayer = false }
            }
            // 锁屏封面由播放器取，它自己没有环境，在这里把提供方递过去
            .onChange(of: ObjectIdentifier(artworkProvider), initial: true) { _, _ in
                player.artworkProvider = artworkProvider
            }
    }
}

extension View {
    /// 挂在 `TabView` 上。「加到歌单」在播放页内部自己弹；`onShowInFolder` 由导航那边接上，
    /// 没接时播放页「⋯」里这一项置灰
    func playerChrome(onShowInFolder: ((Track) -> Void)? = nil) -> some View {
        modifier(PlayerChrome(onShowInFolder: onShowInFolder))
    }
}
