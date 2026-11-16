import SwiftUI
import UIKit

/// 格式胶囊：灰底圆角小标签，大写扩展名
struct FormatTag: View {
    let text: String

    /// 深色 0.2、浅色 0.15；用动态色，两种模式都压得住
    private var tagFill: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 125 / 255, green: 130 / 255, blue: 145 / 255, alpha: 0.2)
                : UIColor(red: 122 / 255, green: 110 / 255, blue: 99 / 255, alpha: 0.15)
        })
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(tagFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            // 胶囊的宽度不能被挤压：长路径截断时，它要保持完整
            .fixedSize()
    }
}

/// 第二行的元信息样式
enum SongMetaStyle: Sendable {
    /// 「格式 · 体积」，歌曲列表用
    case size
    /// 「格式 · 所在路径」，搜索结果用，点路径跳到那个文件夹
    case path
}

/// 歌曲行第二行：格式胶囊 + 体积或路径 + 下载状态
struct SongMeta: View {
    let track: Track
    var style: SongMetaStyle = .size
    /// 可选：预览和测试里没注入乐库，就不显示下载进度（只按 isDownloaded 画云朵）
    @Environment(LibraryStore.self) private var library: LibraryStore?

    var body: some View {
        HStack(spacing: 6) {
            FormatTag(text: track.format)
            switch style {
            case .size:
                Text(CommonFormat.fileSize(track.fileSize))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .fixedSize()
            case .path:
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text(pathText)
                        .lineLimit(1)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
            }
            DownloadStateMark(isDownloaded: track.isDownloaded, progress: library?.downloadProgress[track.path])
        }
    }

    /// 根目录显示「乐库」，子目录用「 › 」连接各级
    private var pathText: String {
        track.folderPath.isEmpty
            ? "乐库"
            : track.folderPath.split(separator: "/").joined(separator: " › ")
    }
}

/// 下载状态：照「文件」App 的习惯，
/// 已在本机的不标，标的是例外——还在云上的画一朵云，正在下载的画一圈进度。
/// 放在第二行末尾而不是时长旁边：时长那一列要对齐，不能被图标顶歪
struct DownloadStateMark: View {
    let isDownloaded: Bool
    /// 正在下载时 0~1；nil 表示没在下载
    let progress: Double?

    var body: some View {
        if let progress {
            ZStack {
                Circle().stroke(Theme.secondary.opacity(0.3), lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: max(0.04, min(progress, 1)))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            .accessibilityLabel("正在下载 \(Int((progress * 100).rounded()))%")
        } else if !isDownloaded {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .accessibilityLabel("未下载")
        }
    }
}

/// 正在播放的喇叭徽章，压在封面左下角。
/// 歌曲行和方格卡片共用，所以尺寸可调
struct NowPlayingBadge: View {
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: size, height: size)
            .background(Theme.accent, in: Circle())
            .accessibilityHidden(true)
    }
}

/// 行底的分隔线：从封面左缘画到右边缘，不从屏幕最左边开始
struct RowSeparator: View {
    /// 分隔线离左边的距离，等于行内容左侧到封面左缘的距离
    var inset: CGFloat

    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// 歌曲行的三种样式
enum SongRowStyle: Equatable, Sendable {
    /// 歌单详情：左侧序号，正在播放的那一行序号换成喇叭
    case numbered(Int)
    /// 文件夹页：不显示序号，正在播放时歌名变强调色、封面左下角加喇叭
    case plain
    /// 搜索结果：第二行显示所在路径，歌名里命中的字强调加粗
    case search(highlight: String)
}

/// 歌曲行：封面 40、歌名一行、第二行格式和体积（或路径）、右侧时长。行高 56。
/// 「是否正在播放」由调用方传入，这个组件不去读播放器。
struct SongRow: View {
    let track: Track
    var style: SongRowStyle = .plain
    var isPlaying: Bool = false
    /// 已收藏的歌在歌名后面标一颗小心形。「最爱」歌单页里每一行都是最爱，再标就是噪音，那里传 false
    var showsFavorite: Bool = true

    /// 可选：预览和测试里没注入歌单，就不标
    @Environment(PlaylistStore.self) private var playlists: PlaylistStore?

    private static let coverSize: CGFloat = 40
    private static let rowHeight: CGFloat = 56
    /// 页边距 16pt
    private static let edge: CGFloat = 16
    private static let numberWidth: CGFloat = 26

    var body: some View {
        HStack(spacing: 12) {
            if case .numbered(let number) = style {
                numberLabel(number)
                    .frame(width: Self.numberWidth, alignment: .leading)
            }
            CoverView(track: track, size: Self.coverSize, cornerRadius: 7)
                .overlay(alignment: .bottomLeading) {
                    // 序号模式下喇叭已经换到序号位置，封面上不再重复画
                    if isPlaying, !isNumbered {
                        NowPlayingBadge()
                            .padding(2)
                    }
                }
            titleBlock
            Text(formatTime(track.duration))
                .font(.system(size: 15))
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
                // 时长不能被歌名挤掉
                .fixedSize()
        }
        .padding(.leading, Self.edge)
        .padding(.trailing, Self.edge)
        .frame(height: Self.rowHeight)
        .overlay(alignment: .bottom) {
            RowSeparator(inset: separatorInset)
        }
        .accessibilityElement(children: .combine)
    }

    private var isNumbered: Bool {
        if case .numbered = style { return true }
        return false
    }

    /// 序号列加上它与封面之间的间距，分隔线要从封面左缘开始
    private var separatorInset: CGFloat {
        isNumbered ? Self.edge + Self.numberWidth + 12 : Self.edge
    }

    @ViewBuilder
    private func numberLabel(_ number: Int) -> some View {
        if isPlaying {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
        } else {
            Text("\(number)")
                .font(.system(size: 15))
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                titleText
                    .font(.system(size: 15.5, weight: isPlaying ? .semibold : .medium))
                    .foregroundStyle(isPlaying ? Theme.accent : Theme.text)
                    .lineLimit(1)
                // 放在歌名后面而不是右侧时长旁：时长那一列要对齐；歌名太长被截断时心形也不能被挤掉
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.accent)
                        .fixedSize()
                        .accessibilityLabel("最爱")
                }
            }
            SongMeta(track: track, style: metaStyle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isFavorite: Bool {
        showsFavorite && (playlists?.isFavorite(track.path) ?? false)
    }

    private var metaStyle: SongMetaStyle {
        if case .search = style { return .path }
        return .size
    }

    private var titleText: Text {
        guard case .search(let query) = style, !query.isEmpty else {
            return Text(track.title)
        }
        return Self.highlighted(track.title, query: query)
    }

    /// 把歌名里所有命中的片段（不分大小写）标成强调色加粗。
    /// 用 AttributedString 而不是 Text 相加：Text 的 `+` 已被系统标记为弃用
    static func highlighted(_ title: String, query: String) -> Text {
        var result = AttributedString(title)
        var cursor = title.startIndex
        while cursor < title.endIndex,
              let found = title.range(of: query, options: .caseInsensitive, range: cursor..<title.endIndex) {
            if let lower = AttributedString.Index(found.lowerBound, within: result),
               let upper = AttributedString.Index(found.upperBound, within: result) {
                // 加粗用语义强调而不是改字号，这样跟着外层字体的大小走
                result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
                result[lower..<upper].foregroundColor = Theme.accent
            }
            cursor = found.upperBound
        }
        return Text(result)
    }
}

#Preview("歌曲行") {
    let songs = CommonPreviewSamples.songs
    VStack(spacing: 0) {
        SongRow(track: songs[0], style: .numbered(1), isPlaying: true)
        SongRow(track: songs[1], style: .numbered(2))
        SongRow(track: songs[2], style: .plain, isPlaying: true)
        SongRow(track: songs[3], style: .plain)
        SongRow(track: songs[4], style: .search(highlight: "夜"))
    }
    .background(Theme.bg)
}

#Preview("歌曲行 深色") {
    let songs = CommonPreviewSamples.songs
    VStack(spacing: 0) {
        SongRow(track: songs[0], style: .numbered(1), isPlaying: true)
        SongRow(track: songs[4], style: .search(highlight: "夜"))
    }
    .background(Theme.bg)
    .preferredColorScheme(.dark)
}
