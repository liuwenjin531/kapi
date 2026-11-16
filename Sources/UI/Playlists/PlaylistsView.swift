import SwiftUI

/// R1 / R1b 歌单页：第一行固定「最爱」，下面是所有歌单；列表 / 方格两种视图。
struct PlaylistsView: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.adaptiveLayout) private var layout

    // 视图和排序只存本机，不同步
    @AppStorage("playlistsViewMode") private var viewMode: PlaylistViewMode = .list
    @AppStorage("playlistsSort") private var sortKey: PlaylistSortKey = .custom

    @State private var editMode: EditMode = .inactive
    @State private var showNew = false
    @State private var showSettings = false
    @State private var pendingDelete: Playlist?
    @State private var errorMessage: String?
    /// 方格列数按可用宽度算：窄（iPhone、外屏）2 列，宽（内屏横放）4 列
    @State private var width: CGFloat = 0

    private var displayed: [Playlist] { PlaylistSorting.sorted(store.playlists, by: sortKey) }
    private var isEditing: Bool { editMode == .active }

    var body: some View {
        Group {
            switch viewMode {
            case .list:
                // 内屏：两列圆角卡片行。拖动排序只有 List 能做，所以编辑顺序时临时回到单列 List
                if layout.isWide && !isEditing { cardListBody } else { listBody }
            case .grid: gridBody
            }
        }
        .background(Theme.bg)
        .navigationTitle("歌单")
        .toolbar { toolbar }
        .environment(\.editMode, $editMode)
        // 切到方格就退出编辑：方格里没有拖动排序，留着「完成」按钮会很怪
        .onChange(of: viewMode) { _, _ in editMode = .inactive }
        .sheet(isPresented: $showNew) { NewPlaylistSheet() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .confirmationDialog(
            pendingDelete.map { "删除歌单「\($0.name)」？" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除歌单", role: .destructive) {
                if let target = pendingDelete { delete(target) }
            }
        } message: {
            Text("只删除歌单本身，里面的歌曲文件不会动。" + LibraryRoot.Location.stored.deletionSyncNote)
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { editMode = .inactive }
            }
        } else {
            // 「＋ / 排序」一个胶囊，「设置」单独一个圆钮。
            // ToolbarItemGroup 内的按钮共用一个胶囊，中间的固定间隔把设置分出去
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showNew = true } label: {
                    Label("新建歌单", systemImage: "plus")
                }
                sortMenu
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
    }

    /// R1c：视图（网格 / 列表）+ 排序 + 编辑顺序
    private var sortMenu: some View {
        Menu {
            Picker("视图", selection: $viewMode) {
                ForEach(PlaylistViewMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            Picker("排序", selection: $sortKey) {
                ForEach(PlaylistSortKey.allCases, id: \.self) { key in
                    Text(key.label).tag(key)
                }
            }
            // 拖动改的是数组顺序，只有显示的就是数组顺序时才有意义
            Button {
                editMode = .active
            } label: {
                Label("编辑顺序", systemImage: "arrow.up.arrow.down")
            }
            .disabled(viewMode != .list || sortKey != .custom || store.playlists.isEmpty)
        } label: {
            // 和乐库页一致：图标跟着当前视图（网格 / 列表）走
            Label("视图与排序", systemImage: viewMode.symbol)
        }
    }

    // MARK: 统计

    private struct Stat {
        var count = 0
        var size: Int64 = 0
        var cover: Track?
    }

    /// 找不到的曲目（文件被删、还没扫到）不计入，和详情页一致
    private func stat(of playlist: Playlist) -> Stat {
        let tracks = playlist.items.compactMap { library.track(at: $0) }
        return Stat(count: tracks.count, size: tracks.reduce(0) { $0 + $1.fileSize }, cover: tracks.first)
    }

    private func favoritesStat() -> Stat {
        let tracks = store.favorites.compactMap { library.track(at: $0) }
        return Stat(count: tracks.count, size: tracks.reduce(0) { $0 + $1.fileSize }, cover: nil)
    }

    // MARK: 列表（R1）

    private var listBody: some View {
        let favorites = favoritesStat()
        return List {
            Section {
                Button { open(Playlist.favoritesID) } label: {
                    FavoritesRow(trackCount: favorites.count, totalSize: favorites.size, showsSubtitle: false)
                }
                .buttonStyle(.plain)
                // 「最爱」不能删、不能挪：它单独在一个 Section，不挂 onMove / 左滑
                .moveDisabled(true)
                .deleteDisabled(true)
                .plainRow()
            }
            Section {
                ForEach(displayed) { playlist in
                    listRow(playlist)
                }
                .onMove(perform: move)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if store.playlists.isEmpty { emptyHint }
        }
    }

    private func listRow(_ playlist: Playlist) -> some View {
        let stat = stat(of: playlist)
        return Button { open(playlist.id) } label: {
            PlaylistRow(playlist: playlist, trackCount: stat.count, totalSize: stat.size,
                        cover: stat.cover, showsSubtitle: false)
        }
        .buttonStyle(.plain)
        .disabled(isEditing)
        // 非自定义排序时显示顺序不是数组顺序，拖动没有意义
        .moveDisabled(sortKey != .custom)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingDelete = playlist } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .plainRow()
    }

    /// 还没有歌单时，「最爱」下面给一句提示（「最爱」本身一直在）
    private var emptyHint: some View {
        VStack {
            Spacer().frame(height: 200)
            Text("点「＋」新建歌单")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: 两列卡片（R1 内屏）

    private var cardListBody: some View {
        let favorites = favoritesStat()
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                Button { open(Playlist.favoritesID) } label: {
                    FavoritesRow(trackCount: favorites.count, totalSize: favorites.size,
                                 showsSubtitle: false, isCard: true)
                }
                .buttonStyle(.plain)
                ForEach(displayed) { playlist in
                    let stat = stat(of: playlist)
                    Button { open(playlist.id) } label: {
                        PlaylistRow(playlist: playlist, trackCount: stat.count, totalSize: stat.size,
                                    cover: stat.cover, showsSubtitle: false, isCard: true)
                    }
                    .buttonStyle(.plain)
                    // 卡片里没有左滑，删除放长按菜单（同方格）
                    .contextMenu {
                        Button(role: .destructive) { pendingDelete = playlist } label: {
                            Label("删除歌单", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .overlay {
            if store.playlists.isEmpty { emptyHint }
        }
    }

    // MARK: 方格（R1b）

    private var gridBody: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: width >= 600 ? 4 : 2)
        let favorites = favoritesStat()
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                Button { open(Playlist.favoritesID) } label: {
                    FavoritesGridCard(trackCount: favorites.count)
                }
                .buttonStyle(.plain)
                ForEach(displayed) { playlist in
                    let stat = stat(of: playlist)
                    Button { open(playlist.id) } label: {
                        PlaylistGridCard(playlist: playlist, trackCount: stat.count, cover: stat.cover)
                            .overlay(alignment: .top) {
                                PlaylistCustomCover(playlist: playlist)
                            }
                    }
                    .buttonStyle(.plain)
                    // 方格里没有左滑，删除放长按菜单
                    .contextMenu {
                        Button(role: .destructive) { pendingDelete = playlist } label: {
                            Label("删除歌单", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: 动作

    private func open(_ id: Playlist.ID) {
        router.playlistsPath.append(.playlist(id))
    }

    private func move(from source: IndexSet, to destination: Int) {
        do {
            try store.movePlaylists(from: source, to: destination)
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func delete(_ playlist: Playlist) {
        do {
            try store.delete(playlist.id)
        } catch {
            errorMessage = error.userMessage
        }
    }
}

private extension View {
    /// List 里的自绘行：去掉系统的内边距、分隔线和底色，行自己画分隔线
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#Preview("歌单页") {
    NavigationStack { PlaylistsView() }
        .environment(PlaylistStore())
        .environment(LibraryStore())
        .environment(AppRouter())
}
