import AVFoundation
import MediaPlayer
import Observation
import OSLog
import UIKit

/// 播放模式三态。不跨启动保存
enum PlayMode: Sendable, CaseIterable {
    /// 循环顺序（默认）
    case sequential
    /// 单曲循环。手动点「下一首」照样切歌，只有自然播完才重播
    case repeatOne
    /// 随机，每一轮重新洗牌
    case shuffle
}

/// 睡眠定时的选项（15 / 30 / 45 / 60 分钟、播完这首、关闭）
enum SleepTimer: Hashable, Sendable {
    case off
    case minutes(Int)
    case endOfTrack
}

/// 播放器：`AVPlayer`、后台播放、锁屏与控制中心、拔耳机暂停、睡眠定时、
/// 没下载的歌先下载再播、预下载下一首。
///
/// 队列里存的是 `Track` 值的快照；按 `path` 认同一首歌（`Track` 的其他字段会随扫描刷新，不能整个比较）。
@Observable
@MainActor
final class PlayerService {
    /// 当前曲目，没在播为 nil
    private(set) var currentTrack: Track?
    /// 播放队列（已按当前模式排好的实际播放顺序）
    private(set) var queue: [Track] = []
    /// 想播放（含「正在等下载」）。等下载时为 true，界面显示暂停键，点一下就是取消
    private(set) var isPlaying = false
    /// 当前进度，秒
    private(set) var currentTime: TimeInterval = 0
    /// 切换模式时，进出「随机」会重排队列；三种循环之间切换只是换结束规则
    var mode: PlayMode = .sequential {
        didSet { modeDidChange(from: oldValue) }
    }
    private(set) var sleepTimer: SleepTimer = .off

    // MARK: 新增（相对共享类型的初版）

    /// 当前曲目在 `queue` 里的位置
    private(set) var currentIndex = 0
    /// 当前曲目的时长。优先用扫描时读到的，缺失（0）时等 AVPlayerItem 报
    private(set) var duration: TimeInterval = 0
    /// 正在为它下载的曲目 `path`；没在下载为 nil。界面据此在那一行显示转圈
    private(set) var downloadingPath: String?
    /// 下载进度 0...1。系统只在 `NSMetadataQuery` 里给百分比、对单个 URL 读不到，
    /// 所以目前恒为 0，界面当「不确定进度」只显示转圈
    private(set) var downloadProgress: Double = 0
    /// 睡眠定时按分钟设置时的剩余秒数，每秒刷新；其他情况为 nil
    private(set) var sleepRemaining: TimeInterval?
    /// 最近一次播放失败的原因（下载出错、文件损坏），界面可弹一次提示后调 `dismissError()`
    private(set) var errorMessage: String?
    /// 封面来源，由界面层在出现时注入；锁屏封面靠它取。播放器不自己读文件
    var artworkProvider: (any ArtworkProviding)? {
        didSet { if currentTrack != nil { refreshArtwork() } }
    }

    /// AVPlayer 而不是 AVAudioPlayer：后者只吃纯音频格式，播不了 mp4。
    /// 对外暴露是为了让播放页把它接到 AVPlayerViewController 上显示画面
    let av = AVPlayer()

    @ObservationIgnored private let log = Logger(subsystem: "com.liuwenjin.kapi", category: "player")
    @ObservationIgnored private var unshuffled: [Track] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var sleepDeadline: Date?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    /// 跳转进行中别让时间观察者把滑块拽回去
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var seekGeneration = 0
    /// 打断（来电、Siri）开始时是不是在播，结束后据此决定要不要自动续播
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    /// 已经为哪些 path 触发过预下载，避免每次切歌都重复调
    @ObservationIgnored private var prefetched: Set<String> = []

    /// 进程内唯一的播放器：App 层和小组件的 Intent 共用。
    /// Intent 由系统放到主 App 的进程里执行，得有个不靠 SwiftUI 环境就能拿到播放器的入口。
    /// 只有它会把状态写给小组件
    static let shared = PlayerService(publishesToWidget: true)

    /// 小组件那边的桥。预览、测试里 new 出来的播放器为 nil，不碰 App Group
    @ObservationIgnored private let widget: WidgetBridge?

    init(publishesToWidget: Bool = false) {
        widget = publishesToWidget ? WidgetBridge() : nil
        configureSession()
        // 视频退到后台时 iOS 默认暂停（省电），纯音频才会继续。
        // 不设这条，播 mp4 一锁屏就没声了
        av.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        observeTime()
        observeEnd()
        observeRoute()
        observeInterruption()
        setupRemoteCommands()
        // 启动时先发一份空闲态：上次运行留下的快照可能还写着「播放中」，而这次进程里什么都没有
        widget?.publish(track: nil, isPlaying: false, duration: 0, position: 0, force: true)
    }

    /// 外观切换后重发一份快照（小组件的配色跟着 App 的皮肤走）
    func refreshWidget() {
        widget?.publish(track: currentTrack, isPlaying: isPlaying && downloadingPath == nil,
                        duration: duration, position: currentTime)
    }

    // MARK: - 播放控制

    /// 用 `tracks` 替换队列并从 `startAt` 开始播。没下载的先下载再播
    func play(tracks: [Track], startAt index: Int = 0) {
        guard tracks.indices.contains(index) else { return }
        let first = tracks[index]
        queue = tracks
        unshuffled = tracks
        if mode == .shuffle {
            applyShuffle(keeping: first)
        }
        select(queue.firstIndex { $0.path == first.path } ?? 0)
        begin()
    }

    func pause() {
        // 还在等下载就是取消：不卸掉当前曲目，再点播放会重新开始等
        if downloadingPath != nil { cancelLoading() }
        guard isPlaying else { return }
        av.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard currentTrack != nil, !isPlaying else { return }
        if av.currentItem == nil {
            // 等下载被取消过，或刚播完一首被卸载
            begin()
            return
        }
        activateSession()
        // 睡眠定时到点后暂停的，醒来接着放前先把定时清干净，已由 sleep(.off) 处理
        av.play()
        isPlaying = true
        updateNowPlaying()
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func next() {
        guard !queue.isEmpty else { return }
        // 三种模式播到队尾都回第一首。单曲循环也一样：原地重播只发生在自动播完时，
        // 手动点「下一首」还得能翻页，否则这个键在单曲循环下就成死键了
        if currentIndex + 1 < queue.count {
            select(currentIndex + 1)
        } else {
            if mode == .shuffle { reshuffle() }
            select(0)
        }
        begin()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        // 播过 3 秒以上，「上一首」先回到本曲开头——和系统播放器一致
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        select(currentIndex > 0 ? currentIndex - 1 : queue.count - 1)
        begin()
    }

    /// 跳到指定秒数
    func seek(to time: TimeInterval) {
        // 时长还没读到（0）时不设上限，否则一律被夹成 0
        let clamped = duration > 0 ? min(max(0, time), duration) : max(0, time)
        currentTime = clamped
        // AVPlayer 的 seek 是异步的：完成前报的还是旧位置。这段时间里时间观察者若回写 currentTime，
        // 滑块会先跳回去再跳过来。代号只让最后一次 seek 的完成回调把开关放下
        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true
        av.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeeking = false
            }
        }
        updateNowPlaying()
    }

    /// 三态轮转：循环顺序 → 单曲循环 → 随机
    func cycleMode() {
        switch mode {
        case .sequential: mode = .repeatOne
        case .repeatOne: mode = .shuffle
        case .shuffle: mode = .sequential
        }
    }

    // MARK: - 队列

    /// 跳到队列里的某一首（「接下来播放」里点一行）
    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        select(index)
        begin()
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        resyncIndex()
    }

    func removeFromQueue(at offsets: IndexSet) {
        let removed = Set(offsets.map { queue[$0].path })
        removeTracks(paths: removed)
    }

    /// 插到当前曲目后面（长按菜单「播放下一首」）。队列为空就直接开播
    func playNext(_ track: Track) {
        guard currentTrack != nil else {
            play(tracks: [track])
            return
        }
        queue.insert(track, at: currentIndex + 1)
        if let playingIndex = unshuffled.firstIndex(where: { $0.path == currentTrack?.path }) {
            unshuffled.insert(track, at: playingIndex + 1)
        } else {
            unshuffled.append(track)
        }
        prefetchNext()
    }

    /// 文件被删了：从队列摘掉，正在播的就停
    func evict(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        removeTracks(paths: paths)
    }

    /// 文件在「文件」App 里被挪了位置、重新认领成新 `Track`：按旧 path 换掉队列里的快照。
    /// 不碰 AVPlayer——它打开的文件句柄跟着文件走，同一个卷内移动声音不断
    func relocate(_ moves: [String: Track]) {
        guard !moves.isEmpty else { return }
        queue = queue.map { moves[$0.path] ?? $0 }
        unshuffled = unshuffled.map { moves[$0.path] ?? $0 }
        if let current = currentTrack, let moved = moves[current.path] { currentTrack = moved }
        updateNowPlaying()
    }

    /// 用户在 App 里重命名 / 移动了歌或文件夹：队列里受影响的曲目只换路径和文件 URL，其余字段（标题、时长等）保留。
    /// 不用 `relocate`：它要的是重扫后才有的新 `Track`，而这里路径是确切知道的，立即生效。
    /// 不碰 AVPlayer——同一个卷内改名 / 移动，已打开的文件句柄跟着文件走，声音不断（和 `relocate` 同一个假设）。
    /// 副作用：标题若是没读到标签时用文件名顶的，会短暂显示旧名，等下一次扫描刷新
    func follow(_ changes: [PathChange], documentsURL: URL) {
        guard !changes.isEmpty else { return }
        func moved(_ track: Track) -> Track {
            guard let path = PathMapping.mapped(track.path, by: changes) else { return track }
            return Track(path: path, url: documentsURL.appending(path: path), title: track.title,
                         artist: track.artist, duration: track.duration, fileSize: track.fileSize,
                         format: track.format, hasVideo: track.hasVideo, videoAspect: track.videoAspect,
                         createdAt: track.createdAt, isDownloaded: track.isDownloaded,
                         modifiedAt: track.modifiedAt)
        }
        queue = queue.map(moved)
        unshuffled = unshuffled.map(moved)
        if let current = currentTrack { currentTrack = moved(current) }
        updateNowPlaying()
    }

    /// App 层把 `LibraryStore.downloadProgress[downloadingPath]` 转交进来（系统只在 NSMetadataQuery 里给百分比）。
    /// 没在等下载时忽略，免得下完之后迟到的一次推送又把进度写回去
    func updateDownloadProgress(_ value: Double) {
        guard downloadingPath != nil else { return }
        let clamped = min(max(value, 0), 1)
        if downloadProgress != clamped { downloadProgress = clamped }
    }

    /// 清掉出错提示
    func dismissError() { errorMessage = nil }

    // MARK: - 睡眠定时

    /// 设置睡眠定时；`.off` 取消。到点只暂停不停止，醒来还能接着放
    func sleep(_ timer: SleepTimer) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = timer
        sleepDeadline = nil
        sleepRemaining = nil
        guard case .minutes(let minutes) = timer else { return }

        let deadline = Date.now.addingTimeInterval(Double(minutes) * 60)
        sleepDeadline = deadline
        sleepRemaining = Double(minutes) * 60
        // 比较墙上时间而不是累加 sleep 的次数：进程被挂起时 Task.sleep 会漂
        sleepTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.sleepDeadline == deadline else { return }
                let left = deadline.timeIntervalSinceNow
                if left <= 0 {
                    self.sleepFired()
                    return
                }
                self.sleepRemaining = left.rounded(.up)
            }
        }
    }

    private func sleepFired() {
        sleepTask = nil
        sleepDeadline = nil
        sleepRemaining = nil
        sleepTimer = .off
        pause()
    }

    // MARK: - 内部：选曲与开播

    private func select(_ index: Int) {
        currentIndex = index
        currentTrack = queue.indices.contains(index) ? queue[index] : nil
    }

    /// 队列被改了顺序或内容之后，按 path 重新找到正在播的那首
    private func resyncIndex() {
        guard let path = currentTrack?.path, let i = queue.firstIndex(where: { $0.path == path }) else { return }
        currentIndex = i
    }

    private func removeTracks(paths: Set<String>) {
        let playingPath = currentTrack?.path
        let playingRemoved = playingPath.map { paths.contains($0) } ?? false
        queue.removeAll { paths.contains($0.path) }
        unshuffled.removeAll { paths.contains($0.path) }
        if playingRemoved {
            // 正在播的被删：停掉，指针落在原位置（即删后的「下一首」），但不自动续播
            let keep = min(currentIndex, max(0, queue.count - 1))
            stop()
            select(keep)
            if queue.isEmpty { currentTrack = nil }
        } else {
            resyncIndex()
        }
    }

    /// 开始播 `currentTrack`：本机有就直接播，没有先下载
    private func begin() {
        guard let track = currentTrack else { return }
        cancelLoading()
        currentTime = 0
        duration = track.duration
        isPlaying = true
        errorMessage = nil
        prefetchNext()

        if track.isDownloaded {
            playNow(track)
        } else {
            downloadThenPlay(track)
        }
    }

    private func playNow(_ track: Track) {
        activateSession()
        let item = AVPlayerItem(url: track.url)
        let path = track.path
        statusObservation = Self.observeFailure(of: item) { [weak self] message in
            Task { @MainActor in self?.playbackFailed(message, path: path) }
        }
        av.replaceCurrentItem(with: item)
        av.play()
        isPlaying = true
        loadDurationIfNeeded(for: item, path: track.path)
        refreshArtwork()
        updateNowPlaying()
    }

    private func downloadThenPlay(_ track: Track) {
        // 先把上一首的声音停掉，否则等下载期间还在放上一首
        av.pause()
        av.replaceCurrentItem(with: nil)
        statusObservation = nil
        downloadingPath = track.path
        downloadProgress = 0
        refreshArtwork()
        updateNowPlaying()

        let url = track.url
        let path = track.path
        loadTask = Task { [weak self] in
            var started = false
            let deadline = Date.now.addingTimeInterval(10 * 60)
            while !Task.isCancelled {
                let state = await Task.detached(priority: .userInitiated) { Self.fileState(of: url) }.value
                guard let self, self.currentTrack?.path == path else { return }
                switch state {
                case .local:
                    self.downloadingPath = nil
                    // 取消等待（pause）会先 cancel 本任务，走到这里说明用户还想听
                    if !Task.isCancelled, self.isPlaying { self.playNow(self.currentTrack ?? track) }
                    return
                case .missing:
                    self.playbackFailed("文件不存在，可能已被删除", path: path)
                    return
                case .failed(let message):
                    self.playbackFailed("下载失败：\(message)", path: path)
                    return
                case .remote:
                    if !started {
                        started = true
                        do {
                            try FileManager.default.startDownloadingUbiquitousItem(at: url)
                        } catch {
                            self.playbackFailed("无法开始下载：\(error.localizedDescription)", path: path)
                            return
                        }
                    }
                }
                if Date.now > deadline {
                    self.playbackFailed("下载超时，请检查网络后重试", path: path)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        downloadingPath = nil
        downloadProgress = 0
    }

    private func playbackFailed(_ message: String, path: String) {
        guard currentTrack?.path == path else { return }
        log.error("播放失败 \(path, privacy: .public)：\(message, privacy: .public)")
        cancelLoading()
        av.pause()
        isPlaying = false
        errorMessage = message
        updateNowPlaying()
    }

    private func stop() {
        cancelLoading()
        av.pause()
        av.replaceCurrentItem(with: nil)
        statusObservation = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        updateNowPlaying()
    }

    /// 播放时顺手把下一首下载好（提前 1 首）。下一首是谁：队列里的下一个，到尾回第一个。
    /// 随机模式重洗的那一刻才知道下一轮第一首，预下载不覆盖那种情况，那首照旧走「先下载再播」
    private func prefetchNext() {
        guard queue.count > 1 else { return }
        let nextIndex = currentIndex + 1 < queue.count ? currentIndex + 1 : 0
        let next = queue[nextIndex]
        guard !next.isDownloaded, prefetched.insert(next.path).inserted else { return }
        // 失败了无所谓：真轮到它时 downloadThenPlay 会再试并把错误告诉用户
        try? FileManager.default.startDownloadingUbiquitousItem(at: next.url)
    }

    private func loadDurationIfNeeded(for item: AVPlayerItem, path: String) {
        guard duration <= 0 else { return }
        Task { [weak self] in
            // 失败了无所谓：时长缺失时进度条按 1 秒算，不影响播放
            guard let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite, seconds > 0 else { return }
            guard let self, self.currentTrack?.path == path else { return }
            self.duration = seconds
            self.updateNowPlaying()
        }
    }

    private func trackDidFinish() {
        // 「播完当前这首」优先于单曲循环，否则永远等不到结束
        if sleepTimer == .endOfTrack {
            sleep(.off)
            pause()
            seek(to: 0)
            return
        }
        if mode == .repeatOne {
            seek(to: 0)
            av.play()
        } else {
            next()
        }
    }

    // MARK: - 内部：随机

    private func modeDidChange(from old: PlayMode) {
        guard old != mode, old == .shuffle || mode == .shuffle else { return }
        if mode == .shuffle {
            unshuffled = queue
            applyShuffle(keeping: currentTrack)
        } else if !unshuffled.isEmpty {
            // 退出随机会丢掉手动拖过的顺序，回到进入随机前的顺序
            queue = unshuffled
        }
        resyncIndex()
    }

    /// 打乱，正在播的那首挪到队首：声音不断，换的只是它后面的顺序
    private func applyShuffle(keeping playing: Track?) {
        queue.shuffle()
        if let playing, let i = queue.firstIndex(where: { $0.path == playing.path }) {
            queue.swapAt(0, i)
        }
        currentIndex = 0
    }

    /// 一轮播完重洗。不重洗的话第二轮跟第一轮一模一样，那就不叫随机
    private func reshuffle() {
        let justPlayed = currentTrack
        queue.shuffle()
        // 洗完开头恰好又是刚放完的那首，就跟第二首换一下——接缝处连放两遍同一首听起来像卡带
        if queue.count > 1, queue.first?.path == justPlayed?.path { queue.swapAt(0, 1) }
    }

    // MARK: - 内部：系统集成

    /// 用 AVPlayer 自带的时间观察者，不手写 Timer 轮询：更准也更省电
    private func observeTime() {
        timeObserver = av.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isSeeking, self.av.rate != 0 else { return }
                self.currentTime = time.seconds
            }
        }
    }

    private func observeEnd() {
        let token = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Notification 不是 Sendable，只把能跨线程的标识带进去
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let sender, let item = self.av.currentItem,
                      sender == ObjectIdentifier(item) else { return }
                self.trackDidFinish()
            }
        }
        observers.append(token)
    }

    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
        } catch {
            log.error("设置音频会话失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.error("激活音频会话失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 耳机拔掉、蓝牙断开时系统会把声音转到外放。没人想要这个，直接停。
    /// 做成默认行为而不是开关：没有哪种用户会希望拔了耳机继续外放
    private func observeRoute() {
        let token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let raw,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
                else { return }
                self.pause()
            }
        }
        observers.append(token)
    }

    /// 来电、Siri 等打断（iOS 27 起用新的一对通知）：会话被别的 App 抢走时同步界面状态，
    /// 系统建议续播时才自动接着放。只看带 `interruptionContext` 的失活——
    /// 没有它说明不是被别人打断的，不该动播放状态
    private func observeInterruption() {
        let inactive = NotificationCenter.default.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main
        ) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
            let interrupted = context?.interruptionContext != nil
            MainActor.assumeIsolated {
                guard let self, interrupted else { return }
                self.wasPlayingBeforeInterruption = self.isPlaying && self.downloadingPath == nil
                if self.wasPlayingBeforeInterruption { self.pause() }
            }
        }
        let resumable = NotificationCenter.default.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            let shouldResume = context?.recommendation == .shouldResume
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.wasPlayingBeforeInterruption, shouldResume { self.resume() }
                self.wasPlayingBeforeInterruption = false
            }
        }
        observers.append(contentsOf: [inactive, resumable])
    }

    // MARK: - 锁屏 / 控制中心

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    /// 供外部补写：AVKit 之类的组件销毁时可能把 Now Playing 清掉
    func refreshNowPlaying() { updateNowPlaying() }

    private func refreshArtwork() {
        artworkTask?.cancel()
        nowPlayingArtwork = nil
        guard let track = currentTrack, let provider = artworkProvider else { return }
        artworkTask = Task { [weak self] in
            // 锁屏和灵动岛用不到 1920×1080，600 像素够了
            guard let image = await provider.artwork(for: track, maxPixel: 600), !Task.isCancelled else {
                // 没有封面（或还没下载）：小组件画占位，不能留着上一首的图
                if !Task.isCancelled, let self, self.currentTrack?.path == track.path {
                    self.widget?.setCover(nil, for: track)
                }
                return
            }
            guard let self, self.currentTrack?.path == track.path else { return }
            self.nowPlayingArtwork = Self.lockScreenArtwork(image)
            self.widget?.setCover(image, for: track)
            self.updateNowPlaying()
        }
    }

    /// KVO 回调在改状态的那条线程上触发（常是后台），闭包同样不能在主 actor 里建，理由见下面的 lockScreenArtwork
    nonisolated private static func observeFailure(
        of item: AVPlayerItem, _ onFailure: @escaping @Sendable (String) -> Void
    ) -> NSKeyValueObservation {
        item.observe(\.status) { item, _ in
            guard item.status == .failed else { return }
            onFailure(item.error?.localizedDescription ?? "无法播放这个文件")
        }
    }

    /// 必须在非隔离的地方建这个闭包：在主 actor 里写的闭包会继承主线程隔离，
    /// 而系统在自己的后台队列上调它取图，Swift 6 的隔离检查会直接让 App 崩掉（模拟器上实测）
    nonisolated private static func lockScreenArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private func updateNowPlaying() {
        // 小组件和锁屏共用这个汇合点：切歌、暂停、seek 都会走到这里。
        // 等下载时 isPlaying 为 true 但没有声音，对小组件按「没在放」算
        widget?.publish(track: currentTrack, isPlaying: isPlaying && downloadingPath == nil,
                        duration: duration, position: currentTime)
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            // 等下载时界面是「播放中」，但还没有声音，锁屏上按暂停处理
            MPNowPlayingInfoPropertyPlaybackRate: (isPlaying && downloadingPath == nil) ? 1.0 : 0.0,
        ]
        if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 文件状态

    private enum FileState: Sendable {
        case local, remote, missing, failed(String)
    }

    /// 读 iCloud 下载状态，在后台线程调用。非 iCloud 的普通文件没有这个状态，有文件就算在本机
    private nonisolated static func fileState(of url: URL) -> FileState {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            let placeholder = url.deletingLastPathComponent()
                .appendingPathComponent("." + url.lastPathComponent + ".icloud")
            return manager.fileExists(atPath: placeholder.path) ? .remote : .missing
        }
        let values = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey,
        ])
        guard let status = values?.ubiquitousItemDownloadingStatus else { return .local }
        if status == .current { return .local }
        // 旧的下载错误会一直挂在属性上，只有「还没下完」时才算数
        if let error = values?.ubiquitousItemDownloadingError { return .failed(error.localizedDescription) }
        return .remote
    }
}
