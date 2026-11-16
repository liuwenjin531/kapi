import SwiftUI
import PhotosUI

/// R2 歌单详情。「最爱」也走这个页面：`id == Playlist.favoritesID` 时显示最爱，
/// 没有「⋯」菜单（不能改名、不能换封面、不能删），编辑模式里只能移除、不能挪
struct PlaylistDetailView: View {
    let id: Playlist.ID

    @Environment(PlaylistStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.adaptiveLayout) private var layout

    @State private var editMode: EditMode = .inactive
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showPicker = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    private var isFavorites: Bool { id == Playlist.favoritesID }
    private var playlist: Playlist? { store.playlists.first { $0.id == id } }
    private var isEditing: Bool { editMode == .active }

    /// 一首能显示的歌，连同它在原始 `items` 里的下标。
    /// 找不到的条目（文件被删、还没扫到）不显示但留在歌单里，所以拖动 / 移除要按原始下标来
    private struct Entry: Identifiable {
        let itemIndex: Int
        let track: Track
        var id: String { track.path }
    }

    private var items: [String] { isFavorites ? store.favorites : (playlist?.items ?? []) }

    private var entries: [Entry] {
        items.enumerated().compactMap { index, path in
            library.track(at: path).map { Entry(itemIndex: index, track: $0) }
        }
    }

    var body: some View {
        Group {
            if !isFavorites && playlist == nil {
                ContentUnavailableView("找不到这个歌单", systemImage: "music.note.list",
                                       description: Text("可能已在其他设备上删除"))
            } else {
                content
            }
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 带文字的按钮在 Duo 外屏会留在横栏里，进不了右侧竖条；
                // 图标 + 标题 Label 由系统 toolbar 按图标显示，才会进竖条
                Button {
                    editMode = isEditing ? .inactive : .active
                } label: {
                    if isEditing {
                        Label("完成", systemImage: "checkmark")
                    } else {
                        Label("编辑", systemImage: "pencil")
                    }
                }
                .disabled(!isEditing && entries.isEmpty)
            }
        }
        .alert("重命名歌单", isPresented: $showRename) {
            TextField("歌单名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("好") { rename() }
        }
        .confirmationDialog("删除歌单「\(playlist?.name ?? "")」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除歌单", role: .destructive) { deletePlaylist() }
        } message: {
            Text("只删除歌单本身，里面的歌曲文件不会动。" + LibraryRoot.Location.stored.deletionSyncNote)
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                // 读完就清掉选择，下次选同一张图也能触发
                defer { pickerItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                run { try store.setCover(id, imageData: data) }
            }
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        let entries = entries
        // 只有内屏横放左右拆；内屏竖放保持上下（头部在上、列表在下），原则是「内容多放列，不左右拆」
        if layout == .wideLandscape {
            SplitPage {
                splitHeader(entries: entries)
            } trailing: {
                songList(entries, showsHeader: false)
            }
        } else {
            songList(entries, showsHeader: true)
        }
    }

    private func songList(_ entries: [Entry], showsHeader: Bool) -> some View {
        List {
            if showsHeader {
                header(entries: entries)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if entries.isEmpty {
                emptyHint
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                Button { play(entries, from: position) } label: {
                    SongRow(track: entry.track, style: .numbered(position + 1),
                            isPlaying: player.currentTrack?.path == entry.track.path,
                            showsFavorite: !isFavorites)
                }
                .buttonStyle(.plain)
                .disabled(isEditing)
                // 右滑最爱；左滑先是「移出歌单」（整行划到底触发），再是「加到歌单」（放进别的歌单）
                .songActions(for: entry.track) {
                    Button(role: .destructive) { remove([entry.itemIndex]) } label: {
                        Label("移出歌单", systemImage: "minus.circle")
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            // 最爱没有「移动」的存储操作（加入顺序），所以不挂 onMove
            .onMove(perform: isFavorites ? nil : { source, destination in move(entries, from: source, to: destination) })
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// 没有可显示的歌时的提示。「没歌」也包括歌单里的歌文件都找不到的情况，所以提示不说「歌单是空的」以外的原因
    private var emptyHint: some View {
        ContentUnavailableView {
            Label(isFavorites ? "还没有最爱的歌" : "这个歌单还没有歌",
                  systemImage: isFavorites ? "heart" : "music.note.list")
        } description: {
            Text(isFavorites ? "长按歌曲选「最爱」，或在播放页点心形，就会出现在这里"
                             : "长按歌曲选「加到歌单」，就能放进这里")
        }
        .padding(.top, 24)
    }

    private func header(entries: [Entry]) -> some View {
        let size = entries.reduce(Int64(0)) { $0 + $1.track.fileSize }
        return VStack(spacing: 6) {
            bigCover(first: entries.first?.track, side: 184)
                .padding(.top, 8)
                .padding(.bottom, 10)
            Text(isFavorites ? "最爱" : (playlist?.name ?? ""))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(CommonFormat.countAndSize(count: entries.count, bytes: size))
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
            actionRow(entries: entries)
                .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    /// 内屏横放的左栏（R2 内屏）：大封面、标题、统计、随机 / 播放 / ⋯，左对齐
    private func splitHeader(entries: [Entry]) -> some View {
        let size = entries.reduce(Int64(0)) { $0 + $1.track.fileSize }
        return VStack(alignment: .leading, spacing: 6) {
            // 封面边长跟着左栏宽度走（最大 240），不写死
            SquareCover { side in
                bigCoverContent(first: entries.first?.track, side: side)
            }
            .frame(maxWidth: 240)
            .padding(.bottom, 10)
            Text(isFavorites ? "最爱" : (playlist?.name ?? ""))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            Text(CommonFormat.countAndSize(count: entries.count, bytes: size))
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
            actionRow(entries: entries)
                .padding(.top, 12)
        }
    }

    private func bigCover(first: Track?, side: CGFloat) -> some View {
        bigCoverContent(first: first, side: side)
    }

    @ViewBuilder
    private func bigCoverContent(first: Track?, side: CGFloat) -> some View {
        if isFavorites {
            FavoritesCoverView(size: side)
        } else if let playlist {
            PlaylistCoverView(seed: playlist.name, cover: first, size: side)
                .overlay { PlaylistCustomCover(playlist: playlist) }
        }
    }

    /// 随机 / 播放 / ⋯
    private func actionRow(entries: [Entry]) -> some View {
        HStack(spacing: 10) {
            Button { shuffle(entries) } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 56, height: 46)
                    .background(Theme.card, in: Capsule())
            }
            .accessibilityLabel("随机播放")
            .disabled(entries.isEmpty)
            Button { play(entries, from: 0) } label: {
                Label("播放", systemImage: "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Theme.accent, in: Capsule())
            }
            .disabled(entries.isEmpty)
            // 「⋯」不受「没歌」限制：空歌单也要能改名、删除
            if !isFavorites {
                moreMenu
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                renameText = playlist?.name ?? ""
                showRename = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button { showPicker = true } label: {
                Label("更换封面", systemImage: "photo")
            }
            if playlist?.cover != nil {
                Button { run { try store.setCover(id, imageData: nil) } } label: {
                    Label("恢复默认封面", systemImage: "arrow.uturn.backward")
                }
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("删除歌单", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 56, height: 46)
                .background(Theme.card, in: Capsule())
        }
        .accessibilityLabel("更多")
    }

    // MARK: 动作

    private func play(_ entries: [Entry], from position: Int) {
        guard entries.indices.contains(position) else { return }
        // 从随机模式点「播放」是想按顺序听：切回顺序。单曲循环是用户明确选的，保留
        if player.mode == .shuffle { player.mode = .sequential }
        player.play(tracks: entries.map(\.track), startAt: position)
        if !isFavorites { store.markPlayed(id) }
    }

    private func shuffle(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        player.mode = .shuffle
        player.play(tracks: entries.map(\.track), startAt: Int.random(in: entries.indices))
        if !isFavorites { store.markPlayed(id) }
    }

    /// 把「显示出来的下标」换成原始 `items` 里的下标再交给 store
    private func remove(_ itemIndexes: [Int]) {
        if isFavorites {
            // 最爱按路径切换；先取路径再逐条取消，下标不会在循环里错位
            let paths = itemIndexes.compactMap { store.favorites.indices.contains($0) ? store.favorites[$0] : nil }
            run { for path in paths { try store.toggleFavorite(path) } }
        } else {
            run { try store.remove(at: IndexSet(itemIndexes), from: id) }
        }
    }

    private func move(_ entries: [Entry], from source: IndexSet, to destination: Int) {
        let sourceIndexes = IndexSet(source.map { entries[$0].itemIndex })
        // 目标是「插到第 destination 个可见歌之前」；排在最后就是插到原数组末尾，
        // 中间夹着的找不到的条目因此会落在它们原来相对的位置之后，不会被挤丢
        let target = destination < entries.count ? entries[destination].itemIndex : items.count
        run { try store.move(from: sourceIndexes, to: target, in: id) }
    }

    private func rename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        run { try store.rename(id, to: name) }
    }

    private func deletePlaylist() {
        do {
            try store.delete(id)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// 带类型的 throws 在闭包里推不出来，这里放宽成普通 throws，非 PlaylistError 的当写盘失败
    private func run(_ action: () throws -> Void) {
        do {
            try action()
        } catch let error as PlaylistError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = PlaylistError.writeFailed.userMessage
        }
    }
}

#Preview("歌单详情") {
    NavigationStack { PlaylistDetailView(id: Playlist.favoritesID) }
        .environment(PlaylistStore())
        .environment(LibraryStore())
        .environment(PlayerService())
}
