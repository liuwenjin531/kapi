import CryptoKit
import Foundation
import ImageIO
import UIKit

/// `ArtworkProviding` 的真实实现：内存 + 磁盘两级缓存。
///
/// - 磁盘：每首歌存一张最长边 1024 的 JPEG（`Caches/Kapi/artwork/`），键是「相对路径 + 大小 + 修改时间」。
///   没封面的歌存一个空的 `.none` 标记，下次不再去解析文件。
/// - 内存：按界面要的像素大小缓存解码后的图，列表滚动时不用反复解码。
///
/// 没下载的歌直接返回 nil——读标签 / 抽帧会触发整首下载。
@MainActor
final class ArtworkCache: ArtworkProviding {
    /// 磁盘上存的最长边。播放页的大图也够用，更大的原图没必要留
    private static let storedPixel = 1024

    private let directory: URL
    private let memory = NSCache<NSString, UIImage>()
    /// 同一首歌的多个请求（列表行、迷你条、播放页）共用一次读取
    private var inflight: [String: Task<Data?, Never>] = [:]

    init(directory: URL = LocalCache.directory("artwork")) {
        self.directory = directory
        // 解码后的位图很占内存，限个总量，超了系统自会淘汰
        memory.totalCostLimit = 64 * 1024 * 1024
    }

    func artwork(for track: Track, maxPixel: CGFloat) async -> UIImage? {
        guard track.isDownloaded else { return nil }
        let pixel = max(1, min(Int(maxPixel.rounded(.up)), Self.storedPixel))
        let hash = Self.fileHash(LibraryScan.cacheKey(for: track))
        let memoryKey = "\(hash)@\(pixel)" as NSString
        if let hit = memory.object(forKey: memoryKey) { return hit }

        let base: Data?
        if let running = inflight[hash] {
            base = await running.value
        } else {
            let url = track.url
            let dir = directory
            let task = Task { await Self.loadBase(of: url, hash: hash, directory: dir) }
            inflight[hash] = task
            base = await task.value
            inflight[hash] = nil
        }
        guard let base, !Task.isCancelled, let image = await Self.decode(base, maxPixel: pixel) else { return nil }
        memory.setObject(image, forKey: memoryKey, cost: Int(image.size.width * image.size.height * 4 * image.scale * image.scale))
        return image
    }

    /// 键里有 `/`、中文和 `|`，不能直接当文件名，哈希成定长十六进制
    nonisolated static func fileHash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 先查磁盘，没有再解析文件并写盘。`@concurrent`：读盘、解析都不占主线程
    @concurrent
    private static func loadBase(of url: URL, hash: String, directory: URL) async -> Data? {
        let fm = FileManager.default
        let cover = directory.appending(path: hash + ".jpg")
        let none = directory.appending(path: hash + ".none")
        if let data = try? Data(contentsOf: cover) { return data }
        if fm.fileExists(atPath: none.path(percentEncoded: false)) { return nil }

        // 缓存目录可能被系统清掉了，写之前再确认一遍
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = await MediaReader.readArtwork(at: url, maxPixel: storedPixel) {
            try? data.write(to: cover, options: .atomic)   // 写失败只是下次重读
            return data
        }
        // 确实没有封面：留个标记。读取本身失败（文件读到一半）也会走到这里，
        // 但键里带大小和修改时间，文件一变键就变，标记自然失效
        try? Data().write(to: none, options: .atomic)
        return nil
    }

    /// 按界面需要的大小解码。用 ImageIO 缩略图而不是整张解码再缩，
    /// 40pt 的格子不该为 1024 的图付出整图解码的内存
    @concurrent
    private static func decode(_ data: Data, maxPixel: Int) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
