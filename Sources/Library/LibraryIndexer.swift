import Foundation

/// 扫描结果的后台加工：建树、读标签、维护本机元数据缓存。
///
/// 全部在 actor 里（不在主线程）：几千首歌建树和解标签都不能卡界面。
/// 对外只有一个 `snapshots` 流——主线程拿到最新一份整体替换，不关心中间过程。
actor LibraryIndexer {
    /// 最新快照。`bufferingNewest(1)`：主线程来不及消费时只留最新的，旧的直接丢
    nonisolated let snapshots: AsyncStream<LibrarySnapshot>
    private let continuation: AsyncStream<LibrarySnapshot>.Continuation

    private let documentsURL: URL
    private let cacheFile: URL

    private var items: [ScanItem] = []
    private var metadata: [String: TrackMetadata] = [:]
    private var cacheLoaded = false
    private var cacheDirty = false
    private var lastSave = Date.distantPast

    /// 待读标签的队列、以及「排过队 / 读过 / 读失败」的键。
    /// 失败的键留在集合里，本次运行不再重试：坏文件每次推送都重读会白烧 CPU
    private var queue: [ScanItem] = []
    private var queuedKeys = Set<String>()
    private var workers = 0
    private static let maxWorkers = 3
    private var publishScheduled = false

    init(documentsURL: URL) {
        self.documentsURL = documentsURL
        self.cacheFile = LocalCache.directory("metadata").appending(path: "tracks-v1.json")
        (snapshots, continuation) = AsyncStream.makeStream(of: LibrarySnapshot.self,
                                                           bufferingPolicy: .bufferingNewest(1))
    }

    /// 收到一份新的查询结果。`complete` 表示这是「首轮收集完成」之后的结果（用来放心清理过期缓存：
    /// 收集中途的结果是残缺的，那时清缓存会误删）
    func update(items newItems: [ScanItem], complete: Bool) {
        loadCacheIfNeeded()
        items = newItems

        if complete { pruneCache() }
        for item in newItems where !item.isFolder && item.isDownloaded
            && !LibraryScan.isHidden(item.path) && LibraryScan.isMedia(item.path) {
            let key = LibraryScan.cacheKey(for: item)
            if metadata[key] == nil, queuedKeys.insert(key).inserted { queue.append(item) }
        }
        publish()
        pump()
    }

    func finish() {
        saveCache(force: true)
        continuation.finish()
    }

    // MARK: - 发布

    private func publish() {
        let snapshot = LibraryScan.build(items: items, documentsURL: documentsURL) { [metadata] in metadata[$0] }
        continuation.yield(snapshot)
    }

    /// 读标签是一首一首完成的，每完成一首就重建整棵树太浪费，攒 0.3 秒一起发
    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task {
            // 睡眠被取消也无所谓，照样发布
            try? await Task.sleep(for: .milliseconds(300))
            self.publishScheduled = false
            self.publish()
        }
    }

    // MARK: - 读标签

    private func pump() {
        while workers < Self.maxWorkers, !queue.isEmpty {
            workers += 1
            Task { await self.work() }
        }
    }

    private func work() async {
        while let item = queue.popLast() {
            let url = documentsURL.appending(path: item.path)
            if let meta = await MediaReader.readMetadata(at: url) {
                metadata[LibraryScan.cacheKey(for: item)] = meta
                cacheDirty = true
                schedulePublish()
                saveCache(force: false)
            }
        }
        workers -= 1
        if workers == 0 { saveCache(force: true) }
    }

    // MARK: - 本机缓存

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        // 读不出来（第一次运行、被系统清了、格式升级）就当空缓存，重新读一遍而已
        guard let data = try? Data(contentsOf: cacheFile),
              let loaded = try? JSONDecoder().decode([String: TrackMetadata].self, from: data)
        else { return }
        metadata = loaded
    }

    /// 只保留当前文件还对得上的条目，改名 / 删除 / 内容变了的旧键会一直攒着，不清会无限增长
    private func pruneCache() {
        var live = Set<String>()
        for item in items where !item.isFolder { live.insert(LibraryScan.cacheKey(for: item)) }
        let before = metadata.count
        metadata = metadata.filter { live.contains($0.key) }
        if metadata.count != before { cacheDirty = true }
    }

    /// 非强制时最多 3 秒写一次：批量读标签期间缓存文件可能上 MB，不能每首都重写
    private func saveCache(force: Bool) {
        guard cacheDirty else { return }
        if !force, Date().timeIntervalSince(lastSave) < 3 { return }
        lastSave = Date()
        cacheDirty = false
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        // 写失败只是下次启动要重读，不值得打扰用户
        try? data.write(to: cacheFile, options: .atomic)
    }
}
