import SwiftUI

/// 歌单的封面：有指定曲目就用它的封面，否则画占位色块。
/// 歌单自己的封面图（`Playlist.cover`）不在这里读，需要时由调用方传入曲目。
struct PlaylistCoverView: View {
    /// 占位色块的取色依据，一般传歌单名
    let seed: String
    /// 用哪首歌的封面；nil 时画占位
    var cover: Track?
    var size: CGFloat

    var body: some View {
        if let cover {
            CoverView(track: cover, size: size)
        } else {
            ArtworkPlaceholderView(seed: seed, size: size, cornerRadius: coverRadius(for: size))
        }
    }
}

/// 「最爱」的心形封面：强调色底、白色（深色下为深字）心形。
/// 原本是渐变，这里用纯强调色，省得为它单独加颜色进 Theme。
struct FavoritesCoverView: View {
    var size: CGFloat

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: size * 0.42))
            .foregroundStyle(Theme.onAccent)
            .frame(width: size, height: size)
            .background(Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: coverRadius(for: size), style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 歌单行 / 最爱行共用的排版：封面 68、名称、可选副标题、右侧 ›。
/// 歌单列表只有名称（没有「N 首 · 体积」）；搜索页的歌单行仍要副标题，所以副标题可选。
/// `isCard` 是 Duo 内屏横放的两列卡片行：白色圆角底，不画分隔线。
private struct PlaylistRowLayout<Cover: View>: View {
    let name: String
    var subtitle: String?
    var isCard: Bool
    @ViewBuilder var cover: () -> Cover

    private static var coverSize: CGFloat { 68 }

    var body: some View {
        let leading: CGFloat = isCard ? 12 : 16
        HStack(spacing: 14) {
            // 「最爱」不另加星标：心形封面本身就是标识
            cover()
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, leading)
        .frame(height: Self.coverSize + (isCard ? 16 : 12))
        .background {
            if isCard {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card)
            }
        }
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !isCard { RowSeparator(inset: leading + Self.coverSize + 14) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 歌单行：封面 68，名称，右侧 ›（`showsSubtitle` 时多一行「36 首 · 1.38 GB」）。
struct PlaylistRow: View {
    let playlist: Playlist
    let trackCount: Int
    let totalSize: Int64
    /// 封面用哪首歌的封面；nil 时画占位色块
    var cover: Track? = nil
    var showsSubtitle: Bool = true
    var isCard: Bool = false

    var body: some View {
        PlaylistRowLayout(
            name: playlist.name,
            subtitle: showsSubtitle ? CommonFormat.countAndSize(count: trackCount, bytes: totalSize) : nil,
            isCard: isCard
        ) {
            // 自定义封面图盖在封面位置上，放在行里统一处理，调用方不用再算偏移
            PlaylistCoverView(seed: playlist.name, cover: cover, size: 68)
                .overlay { PlaylistCustomCover(playlist: playlist) }
        }
    }
}

/// 「最爱」行：心形封面 68，名称，封面左上角外侧一颗小星。固定排在歌单列表第一，不能删、不能改名。
struct FavoritesRow: View {
    let trackCount: Int
    let totalSize: Int64
    var showsSubtitle: Bool = true
    var isCard: Bool = false

    var body: some View {
        PlaylistRowLayout(
            name: "最爱",
            subtitle: showsSubtitle ? CommonFormat.countAndSize(count: trackCount, bytes: totalSize) : nil,
            isCard: isCard
        ) {
            FavoritesCoverView(size: 68)
        }
    }
}

#Preview("歌单行") {
    let playlist = CommonPreviewSamples.playlist
    VStack(spacing: 0) {
        FavoritesRow(trackCount: 128, totalSize: 1_480_000_000)
        PlaylistRow(playlist: playlist, trackCount: 36, totalSize: 1_480_000_000, cover: CommonPreviewSamples.songs[1])
        PlaylistRow(playlist: playlist, trackCount: 36, totalSize: 1_480_000_000)
    }
    .background(Theme.bg)
}
