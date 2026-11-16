import SwiftUI

/// 方格里的正方形封面。边长由列宽决定，所以把实际边长交给内容，
/// 让封面按真实尺寸取图（不能写死）。
struct SquareCover<Content: View>: View {
    let content: (CGFloat) -> Content

    init(@ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.content = content
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    content(side)
                        .frame(width: side, height: side)
                }
            }
    }
}

/// 文件夹方格：2×2 拼图封面，名称，副标题「38 首 · 1.20 GB」。
struct FolderGridCard: View {
    let node: FolderNode
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SquareCover { side in
                MosaicCover(tracks: node.coverTracks(), size: side)
            }
            Text(node.name)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(subtitle ?? CommonFormat.countAndSize(count: node.trackCount, bytes: node.totalSize))
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 歌曲方格：方形封面（正在播放时左下角喇叭），歌名最多两行，下面一行是格式胶囊（左）和时长（右）。
/// 歌名固定占两行高度，同一行的卡片底边对齐。
struct SongGridCard: View {
    let track: Track
    var isPlaying: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SquareCover { side in
                CoverView(track: track, size: side)
                    .overlay(alignment: .bottomLeading) {
                        if isPlaying {
                            NowPlayingBadge(size: 20)
                                .padding(3)
                        }
                    }
            }
            Text(track.title)
                .font(.system(size: 15.5, weight: isPlaying ? .semibold : .medium))
                .foregroundStyle(isPlaying ? Theme.accent : Theme.text)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                FormatTag(text: track.format)
                Spacer(minLength: 0)
                Text(formatTime(track.duration))
                    .font(.system(size: 13.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 歌单方格：方形封面，歌单名，「36 首」
struct PlaylistGridCard: View {
    let playlist: Playlist
    let trackCount: Int
    var cover: Track? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SquareCover { side in
                PlaylistCoverView(seed: playlist.name, cover: cover, size: side)
            }
            Text(playlist.name)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text("\(trackCount) 首")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 「最爱」方格：心形封面，其余同歌单方格
struct FavoritesGridCard: View {
    let trackCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SquareCover { side in
                // 和列表一样不加星标，心形封面就是「最爱」的标识
                FavoritesCoverView(size: side)
            }
            Text("最爱")
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text("\(trackCount) 首")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview("方格卡片") {
    let songs = CommonPreviewSamples.songs
    ScrollView {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
            FolderGridCard(node: CommonPreviewSamples.folder.subfolders[0])
            SongGridCard(track: songs[0], isPlaying: true)
            PlaylistGridCard(playlist: CommonPreviewSamples.playlist, trackCount: 36)
            FavoritesGridCard(trackCount: 128)
            SongGridCard(track: songs[4])
        }
        .padding(16)
    }
    .background(Theme.bg)
}
