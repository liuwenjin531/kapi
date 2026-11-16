import Foundation

/// 主 App 写给小组件的「正在播放」快照。
///
/// 小组件是另一个进程，也不能每秒刷新，所以只靠这份快照画界面：
/// 主 App 在曲目、播放状态、外观、进度跳转变化时写一次，小组件按它排时间线。
/// 本文件同时编进主 App 和小组件两个 target，只依赖 Foundation。
struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// 当前认识的格式版本。读到更新的版本就当没有快照（小组件显示空闲态），不去猜新格式
    static let currentVersion = 1

    var version: Int = WidgetSnapshot.currentVersion
    /// `Skin` 的 rawValue。小组件跟 App 里选的皮肤走，不跟系统外观
    var skin: String = "light"
    /// nil = 没有在放的歌（空闲态）
    var nowPlaying: NowPlaying?

    struct NowPlaying: Codable, Equatable, Sendable {
        var trackPath: String
        var title: String
        var artist: String?
        /// 真的在出声。等下载时界面是「播放中」但没声音，这里记 false
        var isPlaying: Bool
        /// 秒；没读到时为 0
        var duration: TimeInterval
        /// 写这份快照那一刻的进度，秒
        var position: TimeInterval
        /// 写这份快照的时刻。进度条起点 = `updatedAt - position`
        var updatedAt: Date
        /// `cover.jpg` 现在是不是这首歌的封面。切歌后新封面还没生成时为 false，小组件画占位
        var hasCover: Bool
    }
}

extension WidgetSnapshot {
    /// 和上一份相比有没有值得重写、重刷的变化。
    ///
    /// 主 App 的播放状态汇合点（锁屏信息更新）在切歌、暂停、seek 时都会调用，
    /// 但小组件的刷新次数有系统预算，所以只有「小组件看得出区别」才写：
    /// 播放中的进度按时间自然推进，推算出的位置和新位置差不多就算没变（不是 seek）。
    func isEquivalent(to previous: WidgetSnapshot, at now: Date = .now) -> Bool {
        guard skin == previous.skin, version == previous.version else { return false }
        switch (nowPlaying, previous.nowPlaying) {
        case (nil, nil):
            return true
        case let (new?, old?):
            guard new.trackPath == old.trackPath, new.title == old.title, new.artist == old.artist,
                  new.isPlaying == old.isPlaying, new.hasCover == old.hasCover,
                  abs(new.duration - old.duration) < 0.5 else { return false }
            let expected = old.isPlaying
                ? old.position + now.timeIntervalSince(old.updatedAt)
                : old.position
            return abs(new.position - expected) < 1.5
        default:
            return false
        }
    }
}

// MARK: - 时间线

/// 小组件某一刻该画什么
enum WidgetDisplay: Equatable, Sendable {
    /// 没有在放的歌
    case idle
    case track(WidgetSnapshot.NowPlaying, Playback)

    enum Playback: Equatable, Sendable {
        /// 播放中：进度条交给系统自己走（`ProgressView(timerInterval:)`），不占刷新次数
        case running(ClosedRange<Date>)
        /// 暂停或等下载：静态进度
        case paused(fraction: Double)
        /// 时长未知：不画进度
        case unknown
    }
}

struct WidgetTimelinePoint: Equatable, Sendable {
    let date: Date
    let display: WidgetDisplay
}

enum WidgetTimeline {
    /// 歌的预计结束时间过后多久切回空闲态。给 App 自己切歌留一点余量
    static let idleGrace: TimeInterval = 2
    /// 暂停状态最多挂多久。App 被系统杀掉时没有收尾回调，快照不会被改写；
    /// 此后点播放键没有东西可放（队列不跨启动保存），所以暂停态不能一直挂着
    static let pausedLifetime: TimeInterval = 30 * 60
    /// 播放中但时长未知时最多挂多久（没有预计结束时间可参考）
    static let unknownLifetime: TimeInterval = 10 * 60

    /// 由快照排出时间线。
    ///
    /// 播放中的快照，除了「现在」还有一个「预计结束时间 + idleGrace」切成空闲态的条目：
    /// App 活着时歌自然切换或暂停都会重新发布、换掉整条时间线，这个条目走不到；
    /// App 被杀掉时，歌的预计结束时间一到小组件自己回到空闲态，不会永远显示「播放中」
    static func plan(_ snapshot: WidgetSnapshot?, now: Date) -> [WidgetTimelinePoint] {
        let idle = [WidgetTimelinePoint(date: now, display: .idle)]
        guard let snapshot, snapshot.version <= WidgetSnapshot.currentVersion,
              let playing = snapshot.nowPlaying else { return idle }

        if playing.isPlaying {
            if playing.duration > 0 {
                let start = playing.updatedAt.addingTimeInterval(-playing.position)
                let end = start.addingTimeInterval(playing.duration)
                let expire = end.addingTimeInterval(idleGrace)
                guard now < expire else { return idle }
                return [
                    WidgetTimelinePoint(date: now, display: .track(playing, .running(start...end))),
                    WidgetTimelinePoint(date: expire, display: .idle),
                ]
            }
            let expire = playing.updatedAt.addingTimeInterval(unknownLifetime)
            guard now < expire else { return idle }
            return [
                WidgetTimelinePoint(date: now, display: .track(playing, .unknown)),
                WidgetTimelinePoint(date: expire, display: .idle),
            ]
        }

        let expire = playing.updatedAt.addingTimeInterval(pausedLifetime)
        guard now < expire else { return idle }
        let playback: WidgetDisplay.Playback = playing.duration > 0
            ? .paused(fraction: min(max(playing.position / playing.duration, 0), 1))
            : .unknown
        return [
            WidgetTimelinePoint(date: now, display: .track(playing, playback)),
            WidgetTimelinePoint(date: expire, display: .idle),
        ]
    }
}

// MARK: - 落盘

/// 快照和封面缩略图放在 App Group 容器里：主 App 写、小组件读。
/// 用文件而不是 UserDefaults：原子写入，读的一方也不用声明新的隐私 API 理由
enum WidgetStore {
    /// 小组件的 kind，主 App 通知刷新时按它找
    static let widgetKind = "NowPlayingWidget"

    /// 组名从 Info.plist 的 `KapiAppGroup` 读，读不到（单元测试）退回正式组名，同分享收件箱的做法
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "KapiAppGroup") as? String
        ?? "group.com.liuwenjin.kapi"

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "Widget", directoryHint: .isDirectory)
    }

    static func snapshotURL(in directory: URL?) -> URL? { directory?.appending(path: "now-playing.json") }
    static func coverURL(in directory: URL?) -> URL? { directory?.appending(path: "cover.jpg") }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 读不到、解不开、版本更新都返回 nil，调用方一律当空闲态：小组件宁可显示空闲也不画错的东西
    static func read(from directory: URL? = WidgetStore.directory) -> WidgetSnapshot? {
        guard let url = snapshotURL(in: directory),
              let data = try? Data(contentsOf: url),
              let snapshot = try? makeDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version <= WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }

    /// 整文件原子覆盖
    static func write(_ snapshot: WidgetSnapshot, to directory: URL? = WidgetStore.directory) throws {
        guard let directory, let url = snapshotURL(in: directory) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try makeEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}

// MARK: - 点击跳转

/// 小组件点一下要主 App 做的事
enum AppLaunchAction: Equatable, Sendable {
    /// 拉起播放页
    case openPlayer
    /// 播放「最爱」
    case playFavorites
}

/// 小组件和主 App 之间约定的链接。只触发上面两个无害动作，别的 App 调用也没有风险
enum WidgetLink {
    static let scheme = "kapi"
    static let player = URL(string: "kapi://player")!
    static let playFavorites = URL(string: "kapi://favorites/play")!

    static func action(for url: URL) -> AppLaunchAction? {
        guard url.scheme == scheme else { return nil }
        switch (url.host(), url.path()) {
        case ("player", ""), ("player", "/"): return .openPlayer
        case ("favorites", "/play"): return .playFavorites
        default: return nil
        }
    }
}
