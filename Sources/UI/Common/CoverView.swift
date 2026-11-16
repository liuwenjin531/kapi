import SwiftUI

/// 封面圆角：约为边长的 14%，最小 7pt。小格子也不会圆得过头。
func coverRadius(for size: CGFloat) -> CGFloat {
    max(7, (size * 0.14).rounded())
}

/// 没有封面时的占位：按 seed 取色块，压一个白色音符。
/// 只认 seed、不认 Track，所以歌单这种没有单独曲目的地方也能用。
struct ArtworkPlaceholderView: View {
    let seed: String
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        Theme.placeholder(for: seed)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.34))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 单首歌的封面。通过环境里的 `artworkProvider` 异步取图，没有图时画占位色块。
struct CoverView: View {
    let track: Track
    var size: CGFloat
    /// 为 nil 时按 `coverRadius(for:)` 算
    var cornerRadius: CGFloat? = nil

    @Environment(\.artworkProvider) private var artworkProvider
    @Environment(\.displayScale) private var displayScale

    /// 图和它属于哪首歌一起存。列表复用行时，旧歌的图不会被当成新歌的封面闪一下
    @State private var loaded: LoadedArtwork?

    private struct LoadedArtwork {
        let path: String
        let image: UIImage
    }

    private var radius: CGFloat { cornerRadius ?? coverRadius(for: size) }

    var body: some View {
        Group {
            if let loaded, loaded.path == track.path {
                Image(uiImage: loaded.image)
                    .resizable()
                    .scaledToFill()
            } else {
                ArtworkPlaceholderView(seed: track.title, size: size, cornerRadius: radius)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
        // 按显示像素取图，实现方据此降采样，避免把 1080p 原图塞进 40pt 的格子
        .task(id: track) {
            let image = await artworkProvider.artwork(for: track, maxPixel: size * displayScale)
            loaded = image.map { LoadedArtwork(path: track.path, image: $0) }
        }
    }
}

/// 文件夹的 2×2 拼图封面。取前四首的封面，不足四首的格子用占位色块补齐；
/// 一首都没有（空文件夹）时显示文件夹图标。
struct MosaicCover: View {
    /// 通常传 `FolderNode.coverTracks()`
    let tracks: [Track]
    var size: CGFloat

    /// 格子之间的缝，露出底下的分隔色（1.5pt）
    private let gap: CGFloat = 1.5

    private var cell: CGFloat { (size - gap) / 2 }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ZStack {
                    Theme.separator
                    Image(systemName: "folder.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(Theme.secondary)
                }
            } else {
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        tile(0)
                        tile(1)
                    }
                    HStack(spacing: gap) {
                        tile(2)
                        tile(3)
                    }
                }
                .background(Theme.separator)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: coverRadius(for: size), style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tile(_ index: Int) -> some View {
        if index < tracks.count {
            CoverView(track: tracks[index], size: cell, cornerRadius: 0)
        } else {
            // seed 带上第一首的路径，同一个文件夹的占位色始终一致
            ArtworkPlaceholderView(
                seed: "\(tracks.first?.path ?? "")#\(index)",
                size: cell,
                cornerRadius: 0
            )
        }
    }
}

#Preview("封面与拼图") {
    HStack(spacing: 12) {
        CoverView(track: CommonPreviewSamples.songs[0], size: 40)
        CoverView(track: CommonPreviewSamples.songs[1], size: 68)
        MosaicCover(tracks: CommonPreviewSamples.folder.coverTracks(), size: 50)
        MosaicCover(tracks: [], size: 50)
    }
    .padding()
    .background(Theme.bg)
}
