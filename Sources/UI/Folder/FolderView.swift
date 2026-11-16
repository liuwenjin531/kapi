import SwiftUI

/// R3 / R3b 文件夹页。根目录和子文件夹共用这一个页面，`path` 为空串是根目录（标题「乐库」）。
struct FolderView: View {
    let path: String

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerService.self) private var player
    @Environment(\.adaptiveLayout) private var layout

    /// 所有文件夹页共用一个视图与排序设置
    @AppStorage("folderViewMode") private var mode: FolderViewMode = .list
    @AppStorage("folderSortKey") private var sortKey: FolderSortKey = .name

    @State private var actions = FolderActions()
    /// 整理（重命名 / 移动 / 拷贝 / 删除 / 加到歌单）的弹窗状态：长按菜单和多选工具条共用，挂在页面上
    @State private var organize = OrganizeModel()
    /// 多选：用系统的 EditMode + `List(selection:)`，选择圈、选中态都是系统的
    @State private var editMode: EditMode = .inactive
    /// 选中的项，值是路径（文件夹和歌的路径不会重名：同一目录下不能同名）
    @State private var selection: Set<String> = []
    /// 列表区域（滚动区）的实际宽度，用来决定方格列数。
    /// 量的是滚动区而不是整页：内屏横放时左边占掉一栏，右栏才是方格真正能用的宽度
    @State private var width: CGFloat = 0

    private var node: FolderNode? { library.node(at: path) }
    private var title: String { path.isEmpty ? "乐库" : (path as NSString).lastPathComponent }
    private var isSelecting: Bool { editMode.isEditing }

    /// 当前选中的项（按页面上现有的节点解析：被别处删掉的自然不在里面）
    private var selectedTarget: OrganizeTarget {
        guard let node else { return OrganizeTarget() }
        return OrganizeTarget(songs: node.tracks.filter { selection.contains($0.path) },
                              folders: node.subfolders.filter { selection.contains($0.path) })
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            // 内屏横放时标题画在左栏里，导航栏再显示一遍就重复了
            .navigationTitle(isSelecting ? "已选 \(selectedTarget.count) 项" : (layout == .wideLandscape ? "" : title))
            .navigationBarTitleDisplayMode(.large)
            .navigationBarBackButtonHidden(isSelecting)
            // 多选的底部工具条是系统 bottomBar，会和标签栏叠在一起，选择期间把标签栏收起来
            .toolbarVisibility(isSelecting ? .hidden : .automatic, for: .tabBar)
            .toolbar { toolbar }
            .environment(\.editMode, $editMode)
            .modifier(FolderActionsModifier(actions: actions, path: path))
            .organizeDialogs(organize)
            .sheet(isPresented: $actions.showSettings) { SettingsView() }
            .onAppear { organize.onFinished = { exitSelecting() } }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if !library.hasLoaded {
            ProgressView("正在读取乐库…")
                .foregroundStyle(Theme.secondary)
        } else if let node {
            if node.subfolders.isEmpty && node.tracks.isEmpty {
                emptyState
            } else {
                list(for: node)
            }
        } else {
            // 别的设备刚把这个文件夹删了
            ContentUnavailableView("文件夹不存在", systemImage: "folder.badge.questionmark",
                                   description: Text("它可能已在其他设备上被删除。"))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("这里还没有歌", systemImage: "music.note")
        } description: {
            Text(LibraryRoot.Location.stored == .icloud
                 ? "可以在「文件」App 或电脑上，往 iCloud 云盘 › 卡皮音乐 里放歌，也可以从下面导入。"
                 : "可以在「文件」App 的「我的 iPhone › 卡皮音乐」里放歌，也可以从下面导入。")
        } actions: {
            Button("导入到此处") { actions.showFileImporter = true }
                .buttonStyle(.borderedProminent)
            Button("新建文件夹") { actions.askNewFolder() }
        }
    }

    @ViewBuilder
    private func list(for node: FolderNode) -> some View {
        if layout == .wideLandscape {
            // 内屏：左边固定标题、统计、随机 / 播放（不放大封面），右边单独滚动
            SplitPage {
                sideHeader(for: node)
            } trailing: {
                scrollingList(for: node, showsHeader: false)
            }
        } else {
            scrollingList(for: node, showsHeader: true)
        }
    }

    @ViewBuilder
    private func scrollingList(for node: FolderNode, showsHeader: Bool) -> some View {
        let folders = FolderSorting.folders(node.subfolders, by: sortKey)
        let tracks = FolderSorting.tracks(node.tracks, by: sortKey)
        // 多选时一律用列表：网格没有系统的选择圈。只是临时切换，不改用户存的视图偏好，退出多选就回到网格
        if mode == .list || isSelecting {
            // 列表模式用 List：歌曲行的左右滑动（最爱、加到歌单）是系统的 swipeActions，只对 List 的行生效。
            // 外观照歌单详情那一套：行自己画分隔线，所以系统的分隔线、内边距、行背景都关掉
            List(selection: $selection) {
                if showsHeader { header(for: node).plainListRow() }
                if !folders.isEmpty {
                    SectionHeader("文件夹").plainListRow()
                    folderRows(folders)
                }
                if !tracks.isEmpty {
                    SectionHeader("歌曲").plainListRow()
                    songRows(tracks)
                }
                // 末尾留白，最后一行不要贴着屏幕底（原来是 ScrollView 的 bottom padding）
                Color.clear.frame(height: 24).plainListRow()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsHeader { header(for: node) }
                    if !folders.isEmpty {
                        SectionHeader("文件夹")
                        folderGrid(folders)
                    }
                    if !tracks.isEmpty {
                        SectionHeader("歌曲")
                        songGrid(tracks)
                    }
                }
                .padding(.bottom, 24)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }

    /// 内屏横放的左栏：大标题（系统导航栏的标题在这个排法下关掉了）、统计、随机（只图标）+ 播放
    private func sideHeader(for node: FolderNode) -> some View {
        let all = node.allTracks
        return VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Text(statsText(for: node))
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 12) {
                Button {
                    player.mode = .shuffle
                    player.play(tracks: all)
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 46, height: 46)
                        .background(Theme.card, in: Circle())
                }
                .accessibilityLabel("随机播放")
                Button {
                    player.play(tracks: all)
                } label: {
                    Label("播放", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(HeaderButtonStyle(prominent: true))
            }
            .disabled(all.isEmpty)
        }
    }

    // MARK: 标题下的统计和播放按钮

    private func header(for node: FolderNode) -> some View {
        let all = node.allTracks
        return VStack(alignment: .leading, spacing: 12) {
            Text(statsText(for: node))
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 12) {
                Button {
                    // 「随机」同时把播放模式切到随机，这样一轮播完重洗，而不是只洗一次
                    player.mode = .shuffle
                    player.play(tracks: all)
                } label: {
                    Label("随机", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(HeaderButtonStyle(prominent: false))
                Button {
                    player.play(tracks: all)
                } label: {
                    Label("播放", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(HeaderButtonStyle(prominent: true))
            }
            .disabled(all.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func statsText(for node: FolderNode) -> String {
        var parts: [String] = []
        if !node.subfolders.isEmpty { parts.append("\(node.subfolders.count) 个文件夹") }
        parts.append("\(node.trackCount) 首")
        parts.append(CommonFormat.fileSize(node.totalSize))
        return parts.joined(separator: " · ")
    }

    // MARK: 列表

    private func folderRows(_ folders: [FolderNode]) -> some View {
        ForEach(folders) { folder in
            if isSelecting {
                // 多选时不放 NavigationLink / Button：点一下是选中，不是进去
                FolderRow(node: folder)
                    .plainListRow()
                    .listRowBackground(selectionBackground(folder.path))
            } else {
                NavigationLink(value: AppRouter.Destination.folder(folder.path)) {
                    FolderRow(node: folder)
                }
                .buttonStyle(.plain)
                // List 里的 NavigationLink 会自带一个箭头，FolderRow 自己已经画了，不隐藏就出现两个
                .navigationLinkIndicatorVisibility(.hidden)
                .folderContextMenu(folder, organize: organize) { beginSelecting(folder.path) }
                .plainListRow()
            }
        }
    }

    /// 选中行的底色：浅浅的强调色，和系统选择圈配合
    private func selectionBackground(_ id: String) -> Color {
        selection.contains(id) ? Theme.accent.opacity(0.14) : Color.clear
    }

    private func songRows(_ tracks: [Track]) -> some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            if isSelecting {
                SongRow(track: track, style: .plain, isPlaying: player.currentTrack?.path == track.path)
                    .contentShape(Rectangle())
                    .plainListRow()
                    .listRowBackground(selectionBackground(track.path))
            } else {
                Button {
                    player.play(tracks: tracks, startAt: index)
                } label: {
                    SongRow(track: track, style: .plain, isPlaying: player.currentTrack?.path == track.path)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .songActions(for: track, swipe: true, onSelect: { beginSelecting(track.path) }, organize: organize)
                .plainListRow()
            }
        }
    }

    // MARK: 方格

    /// 方格列数：窄屏（iPhone、外屏）固定 2 列；内屏按滚动区宽度多放列，取偶数
    private var columns: [GridItem] {
        let count = FolderGridColumns.count(width: width, isWide: layout.isWide)
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: count)
    }

    private func folderGrid(_ folders: [FolderNode]) -> some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(folders) { folder in
                NavigationLink(value: AppRouter.Destination.folder(folder.path)) {
                    FolderGridCard(node: folder)
                }
                .buttonStyle(.plain)
                .folderContextMenu(folder, organize: organize) { beginSelecting(folder.path) }
            }
        }
        .padding(.horizontal, 16)
    }

    private func songGrid(_ tracks: [Track]) -> some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    player.play(tracks: tracks, startAt: index)
                } label: {
                    SongGridCard(track: track, isPlaying: player.currentTrack?.path == track.path)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .songActions(for: track, onSelect: { beginSelecting(track.path) }, organize: organize)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: 多选

    private func beginSelecting(_ id: String) {
        selection = [id]
        withAnimation { editMode = .active }
    }

    private func exitSelecting() {
        selection = []
        withAnimation { editMode = .inactive }
    }

    private func toggleSelectAll() {
        guard let node else { return }
        let all = Set(node.subfolders.map(\.path) + node.tracks.map(\.path))
        selection = selection == all ? [] : all
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            selectionToolbar
        } else {
            browseToolbar
        }
    }

    /// 多选：左上「全选」，标题「已选 N 项」，右上「完成」，底部「移动 / 拷贝 / 加到歌单 / 删除」。
    /// 底部用系统 `.bottomBar`，iPhone Duo 外屏会自动排成竖条
    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        let target = selectedTarget
        let total = (node?.subfolders.count ?? 0) + (node?.tracks.count ?? 0)
        ToolbarItem(placement: .topBarLeading) {
            Button(target.count == total && total > 0 ? "取消全选" : "全选") { toggleSelectAll() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("完成") { exitSelecting() }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            // 系统 bottomBar 里 Label 只显示图标（文字作为无障碍标签），.titleAndIcon 也不生效
            Button { organize.askMove(target) } label: {
                Label("移动", systemImage: "folder")
            }
            .disabled(target.isEmpty)
            Spacer()
            Button { organize.askCopy(target) } label: {
                Label("拷贝", systemImage: "doc.on.doc")
            }
            .disabled(target.isEmpty)
            Spacer()
            // 选中文件夹时，里面的歌（递归）一起算进去
            Button { organize.askAddToPlaylist(target) } label: {
                Label("加到歌单", systemImage: "text.badge.plus")
            }
            .disabled(target.allSongs.isEmpty)
            Spacer()
            Button(role: .destructive) { organize.askDelete(target) } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(target.isEmpty)
        }
    }

    @ToolbarContentBuilder
    private var browseToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { actions.askNewFolder() } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                Divider()
                Button { actions.showFileImporter = true } label: {
                    Label("从「文件」导入", systemImage: "doc.badge.plus")
                }
                Button { actions.showPhotosPicker = true } label: {
                    Label("从相册导入", systemImage: "photo.on.rectangle")
                }
            } label: {
                Label("添加", systemImage: "plus")
            }
            Menu {
                Picker("视图", selection: $mode) {
                    ForEach(FolderViewMode.allCases, id: \.self) { m in
                        Label(m.label, systemImage: m.symbol).tag(m)
                    }
                }
                Picker("排序", selection: $sortKey) {
                    ForEach(FolderSortKey.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
            } label: {
                // 图标跟着当前视图走（网格 / 列表），和菜单里打勾那项一致：
                // 一眼看出现在是哪种排法，也说明这个按钮管视图切换
                Label("视图与排序", systemImage: mode.symbol)
            }
        }
        if path.isEmpty {
            // 「＋ / 排序」一个胶囊，「设置」单独一个圆钮。
            // 相邻的工具栏项会被系统并进同一个玻璃胶囊，用固定间距把设置分开
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button { actions.showSettings = true } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
    }
}

extension View {
    /// 文件夹行 / 卡片的长按菜单：重命名、移动到…、拷贝到…、选择、删除
    func folderContextMenu(_ folder: FolderNode, organize: OrganizeModel,
                           onSelect: @escaping () -> Void) -> some View {
        contextMenu {
            OrganizeMenuItems(model: organize, target: OrganizeTarget(folders: [folder]), onSelect: onSelect)
            Divider()
            Button(role: .destructive) {
                organize.askDelete(OrganizeTarget(folders: [folder]))
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

/// 「随机 / 播放」按钮：播放是强调色实心，随机是卡片底
private struct HeaderButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(prominent ? Theme.onAccent : Theme.accent)
            .padding(.vertical, 12)
            .background(prominent ? Theme.accent : Theme.card,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 方格列数的纯逻辑，单独放便于单测
enum FolderGridColumns {
    /// 每列大约要的宽度（含间距）：内屏右栏约 570pt → 4 列
    static let idealColumnWidth: CGFloat = 130

    static func count(width: CGFloat, isWide: Bool) -> Int {
        guard isWide else { return 2 }
        let fit = Int(width / idealColumnWidth)
        // 取偶数：奇数列最后一行总是缺一块，难看；至少 2 列
        return max(2, fit - fit % 2)
    }
}
