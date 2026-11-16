import SwiftUI

/// 文件夹行：2×2 拼图封面 50，名称，副标题「38 首 · 1.20 GB」，右侧 ›。
/// 搜索结果里传 `subtitle`（如「纯音乐 › 夜曲 · 9 首」），替换默认副标题。
struct FolderRow: View {
    let node: FolderNode
    var subtitle: String? = nil

    private static let coverSize: CGFloat = 50

    var body: some View {
        HStack(spacing: 14) {
            MosaicCover(tracks: node.coverTracks(), size: Self.coverSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(.system(size: 16.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitle ?? CommonFormat.countAndSize(count: node.trackCount, bytes: node.totalSize))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.coverSize + 12)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            RowSeparator(inset: 16 + Self.coverSize + 14)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("文件夹行") {
    VStack(spacing: 0) {
        FolderRow(node: CommonPreviewSamples.folder.subfolders[0])
        FolderRow(node: CommonPreviewSamples.folder.subfolders[1], subtitle: "纯音乐 › 夜曲 · 9 首")
    }
    .background(Theme.bg)
}
