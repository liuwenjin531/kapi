import SwiftUI

extension PlaylistError {
    /// 给用户看的提示文案。歌单相关的页面都走这里，免得各处写出不同的说法
    var userMessage: String {
        switch self {
        case .stillSyncing: "歌单还在同步，稍后再试"
        case .readOnly: "歌单文件来自更新版本的卡皮音乐，这个版本只能查看，不能修改"
        case .notFound: "找不到这个歌单，可能已在其他设备上删除"
        case .notAttached: "乐库还没准备好，稍后再试"
        case .unreadable: "歌单文件读取失败，为避免覆盖已有内容，暂时不能修改"
        case .writeFailed: "保存失败，请稍后再试"
        }
    }
}

/// 歌曲行的操作（X4）：长按菜单，以及（在 `List` 里）左右滑动。
///
/// - 长按菜单：播放下一首、加到歌单、最爱、重命名、移动到…、拷贝到…、（选择）、删除。
/// - 右滑：最爱 / 取消最爱，整行划到底直接触发（随时能再划一次撤回）。
/// - 左滑：加到歌单，不设划到底。调用方可以在它前面再放自己的左滑动作（歌单详情的「移出歌单」）。
/// - 「播放下一首」和「删除」只在长按菜单里：App 的组织方式是文件夹、最爱、歌单，没有用户可见的「播放队列」；
///   删除在 iCloud 里会同步到其他设备、不能恢复，不放进一划就触发的位置。
///
/// 做成修饰符而不是只给文件夹页用：搜索页、歌单详情页的歌曲行也要同一套菜单，
/// 菜单触发的 sheet / 确认框 / 提示都由修饰符自己持有状态，调用方一行搞定。
/// `.swipeActions` 只对 `List` 的行生效；放在 `ScrollView` / 网格里的歌曲行传 `swipe: false`，只有长按菜单。
private struct SongActionsModifier<Trailing: View>: ViewModifier {
    let track: Track
    /// 删除成功后的回调（比如歌单页要刷新），可不传
    var onDeleted: (() -> Void)?
    /// 是否加滑动动作
    var swipe: Bool
    /// 调用方追加的左滑动作，排在「加到歌单」前面（离屏幕边缘最近，整行划到底触发的是它）
    var hasExtraTrailing: Bool
    @ViewBuilder var extraTrailing: () -> Trailing
    /// 进入多选并选中这一首。nil（搜索页、歌单详情没有多选）就不显示「选择」
    var onSelect: (() -> Void)?
    /// 调用方自己的整理弹窗状态。文件夹页传页面级的：这一行移走后，自己持有的弹窗会跟着消失，
    /// 结果提示就弹不出来了。不传就用本行自己的
    var sharedOrganize: OrganizeModel?

    @Environment(PlayerService.self) private var player
    @Environment(PlaylistStore.self) private var playlists
    @Environment(LibraryRoot.self) private var root

    @State private var showAddSheet = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @State private var ownOrganize = OrganizeModel()
    /// 最爱成功切换一次就加一，驱动触觉反馈：滑动按钮收回去之后行上没有别的变化，得有个手感告诉用户成了
    @State private var favoriteTick = 0

    private var organize: OrganizeModel { sharedOrganize ?? ownOrganize }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    player.playNext(track)
                } label: {
                    Label("播放下一首", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    showAddSheet = true
                } label: {
                    Label("加到歌单", systemImage: "text.badge.plus")
                }
                Button {
                    toggleFavorite()
                } label: {
                    if playlists.isFavorite(track.path) {
                        Label("取消最爱", systemImage: "heart.slash")
                    } else {
                        Label("最爱", systemImage: "heart")
                    }
                }
                Divider()
                OrganizeMenuItems(model: organize, target: OrganizeTarget(songs: [track]), onSelect: onSelect)
                Divider()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: swipe) {
                if swipe {
                    Button { toggleFavorite() } label: {
                        if playlists.isFavorite(track.path) {
                            Label("取消最爱", systemImage: "heart.slash")
                        } else {
                            Label("最爱", systemImage: "heart.fill")
                        }
                    }
                    .tint(Theme.accent)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: hasExtraTrailing) {
                if hasExtraTrailing { extraTrailing() }
                if swipe {
                    Button { showAddSheet = true } label: {
                        Label("加到歌单", systemImage: "text.badge.plus")
                    }
                    .tint(Theme.secondary)
                }
            }
            .sensoryFeedback(.success, trigger: favoriteTick)
            .sheet(isPresented: $showAddSheet) {
                AddToPlaylistSheet(track: track)
            }
            .confirmationDialog("删除「\(track.title)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { delete() }
            } message: {
                Text(root.location == .icloud ? "iCloud 里的文件会被删掉，其他设备上也会一起删除。" : "本机上的文件会被删掉，不能恢复。")
            }
            .alert("操作失败", isPresented: errorBinding) {
                Button("好") {}
            } message: {
                Text(errorMessage ?? "")
            }
            .modifier(OwnedOrganizeDialogs(model: ownOrganize, isOwned: sharedOrganize == nil))
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func toggleFavorite() {
        do {
            try playlists.toggleFavorite(track.path)
            favoriteTick += 1
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func delete() {
        guard let files = root.files else {
            errorMessage = PlaylistError.notAttached.userMessage
            return
        }
        // 先把它从播放队列里摘掉（正在播的会停）：文件删掉后继续读会报错
        player.evict(paths: [track.path])
        Task {
            do {
                try await files.delete(track)
                onDeleted?()
            } catch {
                errorMessage = "删除失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 只在行自己持有整理状态时才挂弹窗；用页面级状态时由页面挂
private struct OwnedOrganizeDialogs: ViewModifier {
    let model: OrganizeModel
    let isOwned: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isOwned { content.organizeDialogs(model) } else { content }
    }
}

extension View {
    /// 给歌曲行加上长按菜单（X4）；`swipe` 为 true 时（行必须在 `List` 里）再加左右滑动。
    /// 需要环境里有 `PlayerService`、`PlaylistStore`、`LibraryRoot`
    func songActions(for track: Track, swipe: Bool = false, onDeleted: (() -> Void)? = nil,
                     onSelect: (() -> Void)? = nil, organize: OrganizeModel? = nil) -> some View {
        modifier(SongActionsModifier(track: track, onDeleted: onDeleted, swipe: swipe,
                                     hasExtraTrailing: false, extraTrailing: { EmptyView() },
                                     onSelect: onSelect, sharedOrganize: organize))
    }

    /// 同上，并在左滑里追加调用方自己的动作（排在「加到歌单」前面，整行划到底触发的是它）
    func songActions<Trailing: View>(
        for track: Track,
        onDeleted: (() -> Void)? = nil,
        onSelect: (() -> Void)? = nil,
        organize: OrganizeModel? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        modifier(SongActionsModifier(track: track, onDeleted: onDeleted, swipe: true,
                                     hasExtraTrailing: true, extraTrailing: trailing,
                                     onSelect: onSelect, sharedOrganize: organize))
    }
}
