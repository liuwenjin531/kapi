import AppIntents

/// 小组件按钮和主 App 播放器之间的桥。
///
/// 为什么要有它：三个 Intent 同时编进主 App 和小组件，但 `PlayerService` 只在主 App 里，
/// 所以 Intent 里不能直接碰播放器。遵循 `AudioPlaybackIntent` 的 Intent 由系统放到**主 App 的进程**里执行，
/// 此时主 App 在启动时登记好的 `handler` 就是真正的播放器操作；
/// 在小组件进程里 `handler` 永远是 nil，那里也不会执行 `perform`
@MainActor
enum PlaybackCommandBus {
    enum Command: Sendable {
        case togglePlayPause, next, previous
    }

    static var handler: (@MainActor (Command) -> Void)?

    static func send(_ command: Command) {
        handler?(command)
    }
}

struct TogglePlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "播放或暂停"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandBus.send(.togglePlayPause)
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "下一首"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandBus.send(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "上一首"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandBus.send(.previous)
        return .result()
    }
}
