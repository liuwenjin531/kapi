import Foundation

/// `NSMetadataQuery` 里一条结果的精简快照。
/// 只装 Sendable 的普通值：`NSMetadataItem` 不能跨线程传，所以在查询所在的后台队列里
/// 当场读完属性、转成它，后面的建树、读标签都只认这个。
struct ScanItem: Sendable, Equatable {
    /// 相对 `Documents/` 的路径
    var path: String
    var isFolder: Bool
    var fileSize: Int64
    var createdAt: Date
    var modifiedAt: Date
    /// 内容是否已在本机（`NSMetadataUbiquitousItemDownloadingStatusKey == current`）
    var isDownloaded: Bool
    /// 正在下载时的进度 0~1；没在下载为 nil
    var downloadFraction: Double?
}

/// 读出来的曲目元数据。存进本机 `Caches/`，所以要 Codable
struct TrackMetadata: Codable, Sendable, Equatable {
    var title: String?
    var artist: String?
    var duration: Double
    var hasVideo: Bool
    var videoAspect: Double?
}

/// 一次扫描建出来的结果：整棵树加下载进度。整体交给主线程替换，界面永远拿到自洽的一份
struct LibrarySnapshot: Sendable {
    var root: FolderNode
    var downloadProgress: [String: Double]
}

/// 扫描结果 → 文件夹树的纯逻辑。不碰 iCloud、不碰 UIKit，可以直接在 macOS 上单测。
enum LibraryScan {
    /// 只认这些扩展名。`.lrc` 不进列表，按同名挂到歌上
    static let mediaExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "caf", "m4b",
        "mp4", "m4v", "mov",
    ]
    /// 按扩展名猜是视频（还没读过元数据 / 没下载时用）
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    static func isMedia(_ name: String) -> Bool {
        mediaExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// 任何一级以 `.` 开头都算隐藏，`.kapi/`（歌单数据）和 `.Trash` 之类都靠它挡掉
    static func isHidden(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// 把绝对路径换成相对 `base` 的路径。
    /// 容器 URL 和查询结果里的路径可能一个带 `/private` 前缀、一个不带（`/var` 是 `/private/var` 的软链），
    /// 直接比前缀会漏，所以两边都去掉 `/private` 再比
    static func relativePath(of absolute: String, under base: String) -> String? {
        func normalize(_ p: String) -> String {
            var s = p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
            while s.count > 1, s.hasSuffix("/") { s.removeLast() }
            return s
        }
        let a = normalize(absolute), b = normalize(base)
        guard a.hasPrefix(b + "/") else { return nil }
        let rel = String(a.dropFirst(b.count + 1))
        return rel.isEmpty ? nil : rel
    }

    /// 缓存键：相对路径 + 文件大小 + 修改时间（毫秒）。文件被换掉后键一变，旧缓存自然失效
    static func cacheKey(path: String, fileSize: Int64, modifiedAt: Date) -> String {
        "\(path)|\(fileSize)|\(Int64((modifiedAt.timeIntervalSince1970 * 1000).rounded()))"
    }

    static func cacheKey(for item: ScanItem) -> String {
        cacheKey(path: item.path, fileSize: item.fileSize, modifiedAt: item.modifiedAt)
    }

    static func cacheKey(for track: Track) -> String {
        cacheKey(path: track.path, fileSize: track.fileSize, modifiedAt: track.modifiedAt)
    }

    /// 由扫描结果建树。
    /// - `metadata`：按缓存键取已读过的元数据；没读过（或没下载）就用文件名兜底
    static func build(
        items: [ScanItem],
        documentsURL: URL,
        metadata: (String) -> TrackMetadata?
    ) -> LibrarySnapshot {
        var tracks: [Track] = []
        var folders: [String] = []
        var progress: [String: Double] = [:]
        var seen = Set<String>()

        for item in items where !item.path.isEmpty && !isHidden(item.path) {
            guard seen.insert(item.path).inserted else { continue }
            if item.isFolder {
                // 空文件夹也要留着（用户刚新建的），所以单独收
                folders.append(item.path)
                continue
            }
            let fileName = (item.path as NSString).lastPathComponent
            guard isMedia(fileName) else { continue }

            let ext = (fileName as NSString).pathExtension.lowercased()
            let stem = (fileName as NSString).deletingPathExtension
            // 没下载的文件绝不信缓存以外的任何标签：读标签会触发整首下载
            let meta = item.isDownloaded ? metadata(cacheKey(for: item)) : nil
            let guessedVideo = videoExtensions.contains(ext)

            let title = meta?.title.flatMap { $0.isEmpty ? nil : $0 } ?? stem
            tracks.append(Track(
                path: item.path,
                url: documentsURL.appending(path: item.path),
                title: title,
                artist: meta?.artist,
                duration: meta?.duration ?? 0,
                fileSize: item.fileSize,
                format: ext.uppercased(),
                hasVideo: meta?.hasVideo ?? guessedVideo,
                videoAspect: meta?.videoAspect,
                createdAt: item.createdAt,
                isDownloaded: item.isDownloaded,
                modifiedAt: item.modifiedAt
            ))
            if !item.isDownloaded, let fraction = item.downloadFraction {
                progress[item.path] = min(max(fraction, 0), 1)
            }
        }
        return LibrarySnapshot(root: FolderNode.build(from: tracks, folderPaths: folders),
                               downloadProgress: progress)
    }
}
