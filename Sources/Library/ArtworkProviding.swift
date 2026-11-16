import SwiftUI
import UIKit

/// 界面取封面的唯一入口。
///
/// 列表行、拼图封面、播放页都只认这个协议，不直接读文件：
/// 读标签、抽视频首帧、本机缓存这些事由乐库层实现（`Library/ArtworkCache.swift`），
/// 界面层和乐库层就能分开写、分开测。
/// 没下载的歌不读标签（会触发整首下载），实现方此时返回 nil，界面显示占位色块。
@MainActor
protocol ArtworkProviding: AnyObject {
    /// 这首歌的主封面；没有封面或还没下载时返回 nil。
    /// `maxPixel` 是界面需要的最长边像素，实现方据此缩小，避免把 1080p 原图塞进 40pt 的格子
    func artwork(for track: Track, maxPixel: CGFloat) async -> UIImage?
}

/// 还没接上真实实现时用的占位：永远没有封面
@MainActor
final class NoArtworkProvider: ArtworkProviding {
    func artwork(for track: Track, maxPixel: CGFloat) async -> UIImage? { nil }
}

extension EnvironmentValues {
    /// 由 App 层注入真实实现；预览和测试用默认的占位
    @Entry var artworkProvider: any ArtworkProviding = NoArtworkProvider()
}
