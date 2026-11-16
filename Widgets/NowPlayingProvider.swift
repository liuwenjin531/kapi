import UIKit
import WidgetKit

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let display: WidgetDisplay
    let skin: Skin
    /// 封面缩略图。没有、或不是当前这首的封面时为 nil，视图画占位
    let cover: UIImage?
}

/// 时间线全由主 App 写的快照排出（见 `WidgetTimeline.plan`），这里只负责读文件、转成条目。
/// `.never`：不自己定时刷新，主 App 在状态变化时通知重载；
/// 快照过期（App 被杀、歌放完）靠时间线里的「切成空闲态」条目兜底
struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        Self.sample
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (NowPlayingEntry) -> Void) {
        // 小组件库里预览：有真实数据就用真实的，没有就用示例，免得预览一片空白
        let entries = Self.entries(now: .now)
        completion(context.isPreview ? Self.sample : entries[0])
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: Self.entries(now: .now), policy: .never))
    }

    static func entries(now: Date) -> [NowPlayingEntry] {
        let snapshot = WidgetStore.read()
        let skin = snapshot.flatMap { Skin(rawValue: $0.skin) } ?? .light
        let cover = loadCover(for: snapshot)
        return WidgetTimeline.plan(snapshot, now: now).map {
            NowPlayingEntry(date: $0.date, display: $0.display, skin: skin, cover: cover)
        }
    }

    private static func loadCover(for snapshot: WidgetSnapshot?) -> UIImage? {
        guard snapshot?.nowPlaying?.hasCover == true,
              let path = WidgetStore.coverURL(in: WidgetStore.directory)?.path else { return nil }
        return UIImage(contentsOfFile: path)
    }

    static var sample: NowPlayingEntry {
        let now = Date.now
        let playing = WidgetSnapshot.NowPlaying(
            trackPath: "sample", title: "沧海飞尘", artist: "银临", isPlaying: true,
            duration: 245, position: 69, updatedAt: now, hasCover: false
        )
        let start = now.addingTimeInterval(-69)
        return NowPlayingEntry(
            date: now,
            display: .track(playing, .running(start...start.addingTimeInterval(245))),
            skin: .light, cover: nil
        )
    }
}
