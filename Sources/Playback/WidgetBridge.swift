import UIKit
import WidgetKit
import OSLog

/// 主 App 这一侧：把播放状态和封面缩略图写进 App Group，并通知小组件刷新。
/// 只有主 `PlayerService`（`shared`）持有它，预览和测试里的播放器实例不碰共享容器。
///
/// 写入只在「小组件看得出区别」时发生（见 `WidgetSnapshot.isEquivalent`），
/// 因为小组件的刷新次数有系统预算，不能跟着播放器每 0.25 秒的进度更新走
@MainActor
final class WidgetBridge {
    private let log = Logger(subsystem: "com.liuwenjin.kapi", category: "widget")
    /// 最近一次写下去的快照，用来判断要不要再写，以及封面就绪时在它上面改
    private var last: WidgetSnapshot?
    /// `cover.jpg` 现在对应哪首歌的 path
    private var coverPath: String?
    private var coverTask: Task<Void, Never>?

    /// 播放状态汇合点调用。`track == nil` 表示没有在放的歌（空闲态）
    func publish(track: Track?, isPlaying: Bool, duration: TimeInterval, position: TimeInterval, force: Bool = false) {
        let now = Date.now
        let nowPlaying = track.map {
            WidgetSnapshot.NowPlaying(
                trackPath: $0.path,
                title: $0.title,
                artist: ($0.artist?.isEmpty ?? true) ? nil : $0.artist,
                isPlaying: isPlaying,
                duration: max(duration, 0),
                position: min(max(position, 0), duration > 0 ? duration : position),
                updatedAt: now,
                hasCover: coverPath == $0.path
            )
        }
        let snapshot = WidgetSnapshot(
            skin: UserDefaults.standard.string(forKey: "skin") ?? Skin.light.rawValue,
            nowPlaying: nowPlaying
        )
        if !force, let last, snapshot.isEquivalent(to: last, at: now) { return }
        write(snapshot)
    }

    /// 封面取到了（或确认没有）。`image` 是锁屏用的 600 像素图，这里缩成小组件用的缩略图。
    /// 先落盘封面、再改快照里的 `hasCover`：小组件读到 true 时文件一定已经是新的
    func setCover(_ image: UIImage?, for track: Track) {
        coverTask?.cancel()
        guard let image else {
            coverPath = nil
            updateLast { $0.hasCover = false }
            return
        }
        let path = track.path
        coverTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) {
                Self.thumbnailJPEG(from: image, maxPixel: Self.coverPixels)
            }.value
            guard !Task.isCancelled, let self, let data,
                  let url = WidgetStore.coverURL(in: WidgetStore.directory) else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                self.log.error("写小组件封面失败：\(error.localizedDescription, privacy: .public)")
                return
            }
            self.coverPath = path
            self.updateLast(onlyFor: path) { $0.hasCover = true }
        }
    }

    // MARK: 内部

    /// 小组件进程内存上限约 30 MB，封面缩到这个边长足够清晰，也不会撑爆
    nonisolated static let coverPixels: CGFloat = 360

    /// 在上一份快照上改一项（封面就绪、封面没有）。位置按「到现在为止自然推进」推算，
    /// 不能原样沿用旧位置，否则进度条会倒退
    private func updateLast(onlyFor path: String? = nil, _ change: (inout WidgetSnapshot.NowPlaying) -> Void) {
        guard var snapshot = last, var playing = snapshot.nowPlaying else { return }
        if let path, playing.trackPath != path { return }
        let now = Date.now
        if playing.isPlaying { playing.position += now.timeIntervalSince(playing.updatedAt) }
        playing.updatedAt = now
        let before = playing.hasCover
        change(&playing)
        guard playing.hasCover != before else { return }
        snapshot.nowPlaying = playing
        write(snapshot)
    }

    private func write(_ snapshot: WidgetSnapshot) {
        do {
            try WidgetStore.write(snapshot)
        } catch {
            // 写不了（容器不可用）就让小组件停在旧状态，不影响播放
            log.error("写小组件快照失败：\(error.localizedDescription, privacy: .public)")
            return
        }
        last = snapshot
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetStore.widgetKind)
    }

    /// 缩成最长边不超过 `maxPixel` 的 JPEG。纯函数，单元测试直接测
    nonisolated static func thumbnailJPEG(from image: UIImage, maxPixel: CGFloat) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let ratio = min(1, maxPixel / longest)
        let size = CGSize(width: (image.size.width * ratio).rounded(), height: (image.size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        // 按像素而不是点：scale 取 1，输出的像素数就是 size
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.jpegData(withCompressionQuality: 0.8) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
