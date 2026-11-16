import Foundation

/// 乐库文件列表的来源：iCloud 用 `LibraryQuery`（NSMetadataQuery），本机用 `LocalLibraryQuery`（遍历目录）。
/// 两者都把结果以 `([ScanItem], 首轮是否完成)` 回调出来，后面的加工不区分来源
protocol LibrarySource: AnyObject, Sendable {
    func start()
    func stop()
}

/// 把「文件列表来源 → 后台加工 → 乐库模型」三段接起来，主线程这一侧只做最后的整体替换。
@MainActor
final class LibraryScanner {
    private struct Batch: Sendable {
        var items: [ScanItem]
        var complete: Bool
    }

    private let library: LibraryStore
    private var query: (any LibrarySource)?
    private var indexer: LibraryIndexer?
    private var tasks: [Task<Void, Never>] = []
    private var currentURL: URL?

    init(library: LibraryStore) {
        self.library = library
    }

    /// 开始扫描。同一个根目录重复调用不会重来；换了根目录（比如换了 iCloud 账号）先停掉旧的
    func start(documentsURL: URL, location: LibraryRoot.Location) {
        guard currentURL != documentsURL else { return }
        stop()
        currentURL = documentsURL

        let indexer = LibraryIndexer(documentsURL: documentsURL)
        let (batches, batchSink) = AsyncStream.makeStream(of: Batch.self, bufferingPolicy: .unbounded)
        // 查询回调在它自己的队列上、按顺序 yield，流保证后面的加工也按顺序，不会新旧结果错位
        let onBatch: @Sendable ([ScanItem], Bool) -> Void = { items, complete in
            batchSink.yield(Batch(items: items, complete: complete))
        }
        let query: any LibrarySource = switch location {
        case .icloud: LibraryQuery(documentsURL: documentsURL, handler: onBatch)
        case .local: LocalLibraryQuery(documentsURL: documentsURL, handler: onBatch)
        }
        self.indexer = indexer
        self.query = query

        tasks.append(Task.detached(priority: .utility) {
            for await batch in batches {
                await indexer.update(items: batch.items, complete: batch.complete)
            }
            await indexer.finish()
        })
        tasks.append(Task { [library] in
            for await snapshot in indexer.snapshots {
                // 内容没变就不替换：下载进度推送很频繁，每次都换根会让整个列表跟着重绘
                if !library.hasLoaded || library.root != snapshot.root {
                    library.replace(root: snapshot.root)
                }
                library.updateDownloadProgress(snapshot.downloadProgress)
            }
        })
        // 流在 stop() 里结束，这里把 sink 存起来之外不需要别的引用；
        // 查询停掉后不会再回调，sink 随 query 一起释放，流自然结束
        sinks = batchSink
        query.start()
    }

    func stop() {
        query?.stop()
        sinks?.finish()
        sinks = nil
        for task in tasks { task.cancel() }
        tasks = []
        query = nil
        indexer = nil
        currentURL = nil
    }

    private var sinks: AsyncStream<Batch>.Continuation?
}
