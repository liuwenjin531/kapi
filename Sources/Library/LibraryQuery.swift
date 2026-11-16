import Foundation

/// 对 `NSMetadataQuery` 的封装。
///
/// 用查询而不是自己遍历目录：别的设备改了会推送更新，还能直接拿到每个文件的下载状态与进度。
/// 查询挂在自己的后台串行队列上，通知和属性读取都在那条队列里完成，不占主线程。
/// `NSMetadataQuery` / `NSMetadataItem` 不是 Sendable，所以整个类用「只在这条队列上碰它们」来保证安全，
/// 对外只吐 `ScanItem` 这种普通值。
final class LibraryQuery: LibrarySource, @unchecked Sendable {
    private let query = NSMetadataQuery()
    private let queue = OperationQueue()
    private let documentsPath: String
    private let handler: @Sendable ([ScanItem], Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    /// 首轮收集是否已完成，只在 `queue` 上读写
    private var gathered = false

    /// - `handler`：每次结果变化回调一次（在查询自己的队列上），第二个参数是首轮收集是否已完成
    init(documentsURL: URL, handler: @escaping @Sendable ([ScanItem], Bool) -> Void) {
        documentsPath = documentsURL.path(percentEncoded: false)
        self.handler = handler
        queue.name = "com.liuwenjin.kapi.library-query"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        query.operationQueue = queue
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        // 下载进度会频繁变化，攒半秒再推，省得整棵树一直重建
        query.notificationBatchingInterval = 0.5
    }

    func start() {
        // 通知的注册和 start 都丢到查询自己的队列上做，保证后续所有访问都在同一条队列
        queue.addOperation { [self] in
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: queue) { [weak self] _ in
                    self?.gathered = true
                    self?.collect()
                },
                center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: queue) { [weak self] _ in
                    self?.collect()
                },
            ]
            query.start()
        }
    }

    func stop() {
        queue.addOperation { [self] in
            query.stop()
            for token in observers { NotificationCenter.default.removeObserver(token) }
            observers = []
        }
    }

    /// 把当前全部结果转成 `ScanItem` 交出去。读属性期间暂停更新，避免读到一半结果集变了
    private func collect() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var items: [ScanItem] = []
        items.reserveCapacity(query.resultCount)
        for case let result as NSMetadataItem in query.results {
            if let item = scanItem(from: result) { items.append(item) }
        }
        handler(items, gathered)
    }

    private func scanItem(from result: NSMetadataItem) -> ScanItem? {
        guard let absolute = result.value(forAttribute: NSMetadataItemPathKey) as? String,
              let relative = LibraryScan.relativePath(of: absolute, under: documentsPath)
        else { return nil }

        let types = result.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
        let isFolder = types.contains("public.folder")
        let size = (result.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
        let created = result.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date
        let modified = result.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date

        // 状态缺失时当作已下载：本机刚写入、还没来得及上传的文件可能没有这个属性，
        // 误判成「未下载」会让它永远读不了标签、点了也播不了
        let status = result.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
        let isDownloaded = status == nil || status == NSMetadataUbiquitousItemDownloadingStatusCurrent

        var fraction: Double?
        if !isDownloaded,
           (result.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? NSNumber)?.boolValue == true {
            // 属性是 0~100，Track 一侧统一用 0~1
            let percent = (result.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? NSNumber)?.doubleValue ?? 0
            fraction = percent / 100
        }

        return ScanItem(path: relative, isFolder: isFolder, fileSize: size,
                        createdAt: created ?? modified ?? Date(timeIntervalSince1970: 0),
                        modifiedAt: modified ?? created ?? Date(timeIntervalSince1970: 0),
                        isDownloaded: isDownloaded, downloadFraction: fraction)
    }
}
