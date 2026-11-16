import SwiftUI

/// R4 搜索页：歌单、文件夹、歌曲三组；没输入时显示最近搜索。
/// 内屏横放（`wideLandscape`）左右拆：左边标题、搜索框、分类筛选，右边结果。
struct SearchView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistStore.self) private var playlists
    @Environment(PlayerService.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.adaptiveLayout) private var layout

    @State private var query = ""
    /// 内屏横放左栏的分类筛选；换了查询词就回到「全部」，免得上一次选的分类下这次没结果
    @State private var category: SearchCategory = .all
    /// 最近搜索，换行分隔存成一个字符串（见 `SearchLogic`）
    @AppStorage("recentSearches") private var storedRecents = ""

    private var recents: [String] { SearchLogic.decode(storedRecents) }

    var body: some View {
        Group {
            if layout == .wideLandscape {
                wideBody
            } else {
                compactBody
            }
        }
        .background(Theme.bg)
        .onChange(of: query) { category = .all }
    }

    private func remember(_ text: String) {
        storedRecents = SearchLogic.encode(SearchLogic.adding(text, to: recents))
    }

    // MARK: 窄布局（iPhone、外屏、内屏竖放）

    private var compactBody: some View {
        Group {
            if let q = SearchLogic.normalized(query) {
                results(for: q, category: .all)
            } else {
                recentsView(removable: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("搜索")
        // 搜索框固定挂在大标题下面：
        // - 不用默认的 .automatic：搜索 Tab（role: .search）下它会把框放到底部 / 激活时跳到顶部，
        //   从结果点进文件夹再返回后框还可能整个丢失；导航栏抽屉形式随导航栏一起存在，不会丢。
        // - avoidHidingContent：输入时不让系统收起大标题和工具栏。
        // 系统搜索的一般行为（激活时出现「取消」）仍保留
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "歌单、文件夹、歌曲")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .onSubmit(of: .search) { remember(query) }
    }

    // MARK: 内屏横放

    /// 左边固定：大标题、搜索框、分类筛选；右边单独滚动：结果或最近搜索。
    /// 系统 `.searchable` 在这个排法下会把搜索框放到右上角导航栏，所以这里用自己的输入框
    private var wideBody: some View {
        let q = SearchLogic.normalized(query)
        return SplitPage {
            VStack(alignment: .leading, spacing: 14) {
                Text("搜索")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                SearchField(text: $query) { remember(query) }
                if q != nil {
                    categoryFilter
                } else {
                    Text("可以搜歌单名、文件夹名和歌名。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                }
            }
        } trailing: {
            Group {
                if let q {
                    results(for: q, category: category)
                } else {
                    recentsView(removable: true)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var counts: SearchCounts {
        guard let q = SearchLogic.normalized(query) else { return SearchCounts() }
        let found = library.search(q)
        return SearchCounts(
            playlists: SearchLogic.matchingPlaylists(playlists.playlists, query: q).count,
            folders: found.folders.count,
            tracks: found.tracks.count)
    }

    private var categoryFilter: some View {
        let counts = counts
        return VStack(spacing: 2) {
            ForEach(SearchCategory.allCases, id: \.self) { item in
                let selected = category == item
                Button {
                    category = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13))
                            .frame(width: 18)
                        Text(item.label)
                            .font(.system(size: 14, weight: .medium))
                        Spacer(minLength: 0)
                        Text("\(counts.count(for: item))")
                            .font(.system(size: 13))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondary)
                    }
                    .foregroundStyle(selected ? Theme.accent : Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(selected ? Theme.card : .clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: 最近搜索

    @ViewBuilder
    private func recentsView(removable: Bool) -> some View {
        if recents.isEmpty {
            ContentUnavailableView("搜索乐库", systemImage: "magnifyingglass",
                                   description: Text("输入歌单、文件夹或歌曲的名字。"))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        SectionHeader("最近搜索")
                        Button("清除") { storedRecents = "" }
                            .font(.system(size: 15))
                            .padding(.trailing, 16)
                            .padding(.top, 16)
                    }
                    ForEach(recents, id: \.self) { text in
                        recentRow(text, removable: removable)
                    }
                }
            }
        }
    }

    private func recentRow(_ text: String, removable: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                query = text
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock")
                        .foregroundStyle(Theme.secondary)
                    Text(text)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if removable {
                // 内屏版每条带 ×：删的是单条，「清除」才是全部
                Button {
                    storedRecents = SearchLogic.encode(SearchLogic.removing(text, from: recents))
                } label: {
                    Label("删除这条", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 16))
        .padding(.leading, 16)
        .padding(.trailing, removable ? 4 : 16)
        .frame(height: 46)
        .overlay(alignment: .bottom) { RowSeparator(inset: 16) }
    }

    // MARK: 结果

    @ViewBuilder
    private func results(for q: String, category: SearchCategory) -> some View {
        let matchedLists = category.shows(.playlists) ? SearchLogic.matchingPlaylists(playlists.playlists, query: q) : []
        let found = library.search(q)
        let folders = category.shows(.folders) ? found.folders : []
        let tracks = category.shows(.tracks) ? found.tracks : []
        if matchedLists.isEmpty && folders.isEmpty && tracks.isEmpty {
            ContentUnavailableView.search(text: q)
        } else {
            // 用 List：歌曲行的左右滑动（最爱、加到歌单）只对 List 的行生效。外观见 `plainListRow`
            List {
                if !matchedLists.isEmpty {
                    SectionHeader("歌单").plainListRow()
                    ForEach(matchedLists) { playlist in
                        playlistRow(playlist).plainListRow()
                    }
                }
                if !folders.isEmpty {
                    SectionHeader("文件夹").plainListRow()
                    ForEach(folders) { folder in
                        NavigationLink(value: AppRouter.Destination.folder(folder.path)) {
                            FolderRow(
                                node: folder,
                                subtitle: "\(SearchLogic.pathText(folder.path)) · \(folder.trackCount) 首")
                        }
                        .buttonStyle(.plain)
                        // List 里的 NavigationLink 自带箭头，行自己已经画了
                        .navigationLinkIndicatorVisibility(.hidden)
                        .simultaneousGesture(TapGesture().onEnded { remember(q) })
                        .plainListRow()
                    }
                }
                if !tracks.isEmpty {
                    SectionHeader("歌曲").plainListRow()
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        songRow(track, index: index, in: tracks, query: q).plainListRow()
                    }
                }
                Color.clear.frame(height: 24).plainListRow()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        let tracks = playlists.resolvedTracks(of: playlist.id, in: { library.track(at: $0) })
        return NavigationLink(value: AppRouter.Destination.playlist(playlist.id)) {
            PlaylistRow(
                playlist: playlist,
                trackCount: tracks.count,
                totalSize: tracks.reduce(0) { $0 + $1.fileSize },
                cover: tracks.first)
        }
        .buttonStyle(.plain)
        .navigationLinkIndicatorVisibility(.hidden)
        .simultaneousGesture(TapGesture().onEnded { remember(query) })
    }

    private func songRow(_ track: Track, index: Int, in all: [Track], query q: String) -> some View {
        Button {
            remember(q)
            // 播放的是整个搜索结果，从点的这首开始
            player.play(tracks: all, startAt: index)
        } label: {
            SongRow(track: track, style: .search(highlight: q),
                    isPlaying: player.currentTrack?.path == track.path)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 第二行的路径是单独的点击区：跳到那个文件夹。
        // 不能把按钮嵌进 SongRow 的按钮里，所以在行上叠一块透明热区，位置对着路径文字
        .overlay(alignment: .bottom) {
            Button {
                remember(q)
                router.showFolder(track.folderPath)
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 24)
            .padding(.leading, 112)
            .padding(.trailing, 70)
            .padding(.bottom, 6)
            .accessibilityLabel("前往所在文件夹")
        }
        .songActions(for: track, swipe: true)
    }
}

/// 内屏横放用的自己的搜索框：放大镜、输入、清除钮。卡片底圆角
private struct SearchField: View {
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            TextField("歌单、文件夹、歌曲", text: $text)
                .font(.system(size: 15))
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Label("清除", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
