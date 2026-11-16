import SwiftUI

@main
struct KapiApp: App {
    // 方向控制（平时锁竖屏，全屏看 MV 才放开横屏）只能从 AppDelegate 进
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // 各 store 在 App 层只创建一次、通过环境往下传：
    // 界面不自己 new，这样各页面读写的永远是同一份数据
    @State private var libraryRoot = LibraryRoot()
    @State private var library: LibraryStore
    /// iCloud 查询 → 乐库模型的接线；创建时需要 library，所以放在 init 里一起建
    @State private var scanner: LibraryScanner
    /// 封面的两级缓存，通过环境交给所有要显示封面的界面
    @State private var artwork = ArtworkCache()
    @State private var playlists = PlaylistStore()
    /// 每首歌的歌词时间微调
    @State private var lyricOffsets = LyricOffsetStore()
    /// 进程内唯一的播放器（小组件的 Intent 也要拿到它），见 `PlayerService.shared`
    @State private var player = PlayerService.shared
    /// 全 App 的导航状态（Tab + 各栈的路径），在 App 层建一次，三个 Tab 和跨 Tab 跳转共用
    @State private var router = AppRouter()
    /// 「用其他应用打开」、隔空投送、分享扩展带来的待导入文件
    @State private var received = ReceivedFiles()
    /// 歌单自定义封面的读取与缓存
    @State private var playlistCovers = PlaylistCoverProvider()
    /// 外观只有浅色 / 深色两项，没有「跟随系统」
    @AppStorage("skin") private var skin: Skin = .light
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = LibraryStore()
        _library = State(initialValue: library)
        _scanner = State(initialValue: LibraryScanner(library: library))
        // 小组件的按钮由系统放到本进程里执行（AudioPlaybackIntent），在这里把它们接到播放器上
        PlaybackCommandBus.handler = { command in
            let player = PlayerService.shared
            switch command {
            case .togglePlayPause: player.togglePlayPause()
            case .next: player.next()
            case .previous: player.previous()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            // 最外层状态：首次选位置 / 正在准备 / iCloud 不可用 / 主界面
            Group {
                switch libraryRoot.state {
                case .needsChoice:
                    LibraryChoiceView { libraryRoot.choose($0) }
                case .preparing:
                    PreparingView()
                case .unavailable:
                    ICloudUnavailableView(
                        onRetry: { libraryRoot.refresh() },
                        onUseLocal: { libraryRoot.choose(.local) }
                    )
                case .ready:
                    RootView()
                }
            }
            .environment(libraryRoot)
            .environment(library)
            .environment(playlists)
            .environment(lyricOffsets)
            .environment(player)
            .environment(router)
            .environment(received)
            .environment(\.playlistCovers, playlistCovers)
            .environment(\.artworkProvider, artwork)
            .preferredColorScheme(skin.scheme)
            .tint(Theme.accent)
            // 「收到文件」：乐库就绪才弹，没就绪（首次选择页、准备中、iCloud 不可用）先存着。
            // 挂在最外层、整个 RootView 之上：播放页等 sheet 是 RootView 里面弹的，
            // 它们开着时这个 sheet 会等到关了才出现（见汇报）
            .sheet(isPresented: Binding(
                get: { received.isPresented && libraryRoot.documentsURL != nil },
                set: { if !$0 { received.dismiss() } }
            )) {
                ReceiveFilesSheet()
                    .environment(libraryRoot)
                    .environment(library)
                    .environment(received)
                    .preferredColorScheme(skin.scheme)
                    .tint(Theme.accent)
            }
            .task { libraryRoot.start() }
            // 容器可用就开始扫描；不可用 / 换账号时停掉旧的，换了根目录再重新开始
            // 小组件点击：打开播放页 / 播放最爱
            .onOpenURL { url in
                // 文件 URL：别的 App 的「打开方式」、隔空投送。攒成一批，由下面的 sheet 处理
                if url.isFileURL {
                    received.add([url])
                    return
                }
                guard let action = WidgetLink.action(for: url) else { return }
                router.pendingAction = action
                runPendingAction()
            }
            // 冷启动时乐库还在读，「播放最爱」等读完再执行
            .onChange(of: library.hasLoaded) { _, _ in runPendingAction() }
            // 外观切换后小组件的配色要跟着变
            .onChange(of: skin) { _, _ in player.refreshWidget() }
            .onChange(of: libraryRoot.state, initial: true) { _, state in
                // 乐库不可用时不会再有「读完」的那一刻，留着的动作会在以后某次恢复时突然开播，先清掉
                if state == .unavailable { router.pendingAction = nil }
                if let url = libraryRoot.documentsURL {
                    // 先挂歌单再开扫描：扫描结果触发的路径认领要在歌单已读入之后
                    // 认领表按位置分开存：本机和 iCloud 是两套乐库，同名路径的歌大小不同，混用会认错
                    playlists.attach(
                        documentsURL: url,
                        sizesFile: LocalCache.root.appending(path: "relocate-sizes-\(libraryRoot.location.rawValue).json")
                    )
                    lyricOffsets.attach(documentsURL: url)
                    playlistCovers.attach(documentsURL: url)
                    scanner.start(documentsURL: url, location: libraryRoot.location)
                    collectShareInbox()
                } else if state == .unavailable {
                    scanner.stop()
                }
            }
            // 切换乐库位置（设置里切、报错页改用本机）：旧那一套的东西全部清掉，
            // 新位置的歌单、扫描由上面 state 变成 ready 时重新挂上
            .onChange(of: libraryRoot.location) { _, _ in
                player.evict(paths: Set(player.queue.map(\.path)))
                router.resetPaths()
                router.pendingAction = nil
                library.reset()
                scanner.stop()
            }
            // 每次扫描结果更新：歌单、最爱、播放队列里「旧路径不见了」的，按文件名 + 大小认领到新路径
            .onChange(of: library.root) { _, root in
                guard libraryRoot.documentsURL != nil else { return }
                let tracks = root.allTracks
                playlists.relocate(using: tracks)
                lyricOffsets.relocate(using: tracks)
                player.relocate(QueueRelocation.moves(queue: player.queue, live: tracks))
            }
            // 下载进度：系统只在 NSMetadataQuery 里给，由 App 层转给播放器，播放页 / 迷你条据此显示
            .onChange(of: library.downloadProgress) { _, _ in syncDownloadProgress() }
            .onChange(of: player.downloadingPath) { _, _ in syncDownloadProgress() }
            // 分享扩展是另一个进程，塞完文件没法通知主 App，只能每次回到前台来看一眼
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    collectShareInbox()
                    // 别的设备改过歌单，回到前台重读一遍
                    playlists.reload()
                    lyricOffsets.reload()
                }
            }
        }
    }

    /// 执行小组件带来的动作。「打开播放页」由 `PlayerChrome` 自己接；这里只管「播放最爱」：
    /// 乐库读完才有曲目可查，没读完就先留着，等 `library.hasLoaded` 变化再来
    private func runPendingAction() {
        guard router.pendingAction == .playFavorites, library.hasLoaded else { return }
        router.pendingAction = nil
        let tracks = playlists.resolvedFavorites { library.track(at: $0) }
        guard !tracks.isEmpty else { return }
        // 想听最爱就按顺序放：从随机切回顺序，单曲循环是用户明确选的，保留（同歌单页「播放」）
        if player.mode == .shuffle { player.mode = .sequential }
        player.play(tracks: tracks)
    }

    private func syncDownloadProgress() {
        guard let path = player.downloadingPath else { return }
        player.updateDownloadProgress(library.downloadProgress[path] ?? 0)
    }

    /// 把分享收件箱里的文件交给「收到文件」sheet，由用户选文件夹后导入。
    /// 这里不删：导入成功才清，失败的留在收件箱，下次回前台再试；重复收集由 `ReceivedFiles` 去重
    private func collectShareInbox() {
        received.add(ShareInbox.pending())
    }
}

/// 三个 Tab：歌单、乐库、搜索。每个 Tab 自带一个 NavigationStack，路径绑在 `AppRouter` 上，
/// 这样播放页「前往所在文件夹」这类跨 Tab 跳转能直接改路径。
/// 导航栏、工具栏一律用系统控件（到 iPhone Duo 上会自动移到右侧竖条）
struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab("歌单", systemImage: "music.note.list", value: AppRouter.TabID.playlists) {
                NavigationStack(path: $router.playlistsPath) {
                    PlaylistsView().appDestinations()
                }
            }
            // Tab 图标：歌单、文件夹、放大镜——乐库就是一个文件夹
            Tab("乐库", systemImage: "folder", value: AppRouter.TabID.library) {
                NavigationStack(path: $router.libraryPath) {
                    FolderView(path: "").appDestinations()
                }
            }
            // 搜索 Tab 用系统的 search 角色，选中时搜索框直接出现在底部
            Tab(value: AppRouter.TabID.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView().appDestinations()
                }
            }
        }
        .background(Theme.bg)
        // 迷你条（tabViewBottomAccessory）和播放页 sheet
        .playerChrome(onShowInFolder: { router.showFolder($0.folderPath) })
        // 最后量尺寸：Duo 内屏 / 外屏 / iPhone 用哪种排法，注入给下面所有页面和弹出层
        .resolvesAdaptiveLayout()
    }
}
