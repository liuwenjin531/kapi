import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// 读文件内容（标签、内嵌封面、视频首帧）。全部是后台函数，调用方在主线程也不会卡。
/// 只能对「已下载」的文件调用：没下载的读一下就会把整首拉下来（6K 的 MV 一个几百 MB）。
enum MediaReader {
    /// 读标题、艺人、时长、视频轨与宽高比。读不出来（坏文件、格式不支持）返回 nil。
    @concurrent
    static func readMetadata(at url: URL) async -> TrackMetadata? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.isNumeric, duration.seconds > 0,
              let common = try? await asset.load(.commonMetadata)
        else { return nil }

        var title: String?, artist: String?
        for item in common {
            switch item.commonKey {
            case .commonKeyTitle: title = await string(of: item)
            case .commonKeyArtist: artist = await string(of: item)
            default: break
            }
        }

        // 视频轨决定播放页显示画面还是黑胶；宽高比决定画面框的形状
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var aspect: Double?
        if let track = videoTracks.first, let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            // 竖版视频的宽高常常记在 transform 里而不是 naturalSize，要应用一下才准
            let shown = size.applying(transform)
            let w = abs(shown.width), h = abs(shown.height)
            if w > 0, h > 0 { aspect = w / h }
        }
        return TrackMetadata(title: title, artist: artist, duration: duration.seconds,
                             hasVideo: !videoTracks.isEmpty, videoAspect: aspect)
    }

    /// 取封面：先找内嵌图片，没有且是视频就抽一帧。结果缩成最长边不超过 `maxPixel` 的 JPEG。
    /// 没有封面返回 nil。
    @concurrent
    static func readArtwork(at url: URL, maxPixel: Int) async -> Data? {
        let asset = AVURLAsset(url: url)
        if let embedded = await images(in: asset).first,
           let data = downscaledJPEG(from: embedded, maxPixel: maxPixel) {
            return data
        }
        // 视频通常没有内嵌封面，抽首帧兜底，否则列表和灵动岛都只有占位色块
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              let duration = try? await asset.load(.duration), duration.isNumeric
        else { return nil }
        return await frame(from: asset, duration: duration.seconds, maxPixel: maxPixel)
    }

    // MARK: - 内部

    private static func string(of item: AVMetadataItem) async -> String? {
        let value = (try? await item.load(.stringValue))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// 抽视频帧当封面。
    /// 不能只取开头：MV 片头常有几秒黑场、白场或纯色淡入，抽出来就是一块纯色。
    /// 所以按 10%/25%/50%/1s 依次试，挑第一个有内容的
    private static func frame(from asset: AVURLAsset, duration: Double, maxPixel: Int) async -> Data? {
        let gen = AVAssetImageGenerator(asset: asset)
        // 竖版视频的方向记在 transform 里，不应用的话抽出来的帧是躺倒的
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)

        var fallback: Data?
        for fraction in [0.10, 0.25, 0.50] + [1.0 / max(duration, 1)] {
            let at = CMTime(seconds: duration * min(max(fraction, 0), 1), preferredTimescale: 600)
            guard let (image, _) = try? await gen.image(at: at), let data = jpeg(image) else { continue }
            if !FrameAnalysis.isFlat(image) { return data }
            fallback = fallback ?? data
        }
        // 整部片子都是纯色也得给张图，总比占位色块好
        return fallback
    }

    /// 挖出文件里所有内嵌图片。
    /// 不用 commonKeyArtwork：它只给一张，而且对非「封面正面」类型的图（手机上这批是
    /// type=0 Other）取不取得到都不好说。这里遍历每种元数据格式的每一项，
    /// 凡是 dataValue 的头几个字节像图片就收下，格式无关，多张也不漏
    static func images(in asset: AVURLAsset) async -> [Data] {
        var found: [Data] = []
        var seen = Set<Data>()

        func collect(_ items: [AVMetadataItem]) async {
            for item in items {
                guard let data = try? await item.load(.dataValue),
                      FrameAnalysis.isImage(data), seen.insert(data).inserted else { continue }
                found.append(data)
            }
        }

        if let common = try? await asset.load(.commonMetadata) { await collect(common) }
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let items = try? await asset.loadMetadata(for: format) { await collect(items) }
            }
        }
        return found
    }

    /// ImageIO 缩略图 + 重新编码 JPEG。直接解码原图再缩会把 3000×3000 的封面整张展开进内存
    private static func downscaledJPEG(from data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary)
        else { return nil }
        return jpeg(image)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
