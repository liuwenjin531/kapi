import Foundation
import UIKit

/// 本机乐库的「查询」：和 `LibraryQuery` 同形，但靠遍历目录。
///
/// 本机文件没有 `NSMetadataQuery` 可用，也就没有变化推送，所以在这几个时机重扫一遍：
/// 启动时；回到前台（用户可能刚在「文件」App 里拖了歌进来）；App 自己改了文件（`LibraryFiles.didChange`）。
/// 产出和 iCloud 一样的 `ScanItem`，后面的 `LibraryIndexer` / `LibraryStore` 不用区分来源。
final class LocalLibraryQuery: LibrarySource, @unchecked Sendable {
    private let documentsURL: URL
    private let handler: @Sendable ([ScanItem], Bool) -> Void
    /// 遍历和防抖都在这条串行队列上，`observers` / `pending` 只在这里读写
    private let queue = DispatchQueue(label: "com.liuwenjin.kapi.local-library-query", qos: .utility)
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var running = false

    init(documentsURL: URL, handler: @escaping @Sendable ([ScanItem], Bool) -> Void) {
        self.documentsURL = documentsURL
        self.handler = handler
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let center = NotificationCenter.default
            observers = [UIApplication.didBecomeActiveNotification, LibraryFiles.didChange].map { name in
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    self?.scheduleScan()
                }
            }
            // 首轮直接以 complete = true 交出：LibraryIndexer 要等首轮完整结果才清理过期缓存
            scan()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            pending?.cancel()
            pending = nil
            for token in observers { NotificationCenter.default.removeObserver(token) }
            observers = []
        }
    }

    /// 合并 0.3 秒内的多次触发：批量导入时每拷一个文件都会发通知，没必要每次都整棵遍历
    private func scheduleScan() {
        queue.async { [self] in
            guard running else { return }
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.scan() }
            pending = work
            queue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func scan() {
        guard running else { return }
        handler(Self.enumerate(documentsURL: documentsURL), true)
    }

    /// 遍历整个乐库目录，转成 `ScanItem`。隐藏项（含 `.kapi/`）和根目录下的 `Inbox/` 整个跳过，不往里走
    static func enumerate(documentsURL: URL) -> [ScanItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        // 枚举出的 URL 和根目录可能一个带 /private 前缀、一个不带，relativePath 里统一处理
        let basePath = documentsURL.path(percentEncoded: false)
        guard let enumerator = FileManager.default.enumerator(
            at: documentsURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [ScanItem] = []
        for case let url as URL in enumerator {
            guard let relative = LibraryScan.relativePath(of: url.path(percentEncoded: false), under: basePath),
                  !relative.isEmpty
            else { continue }
            // 根目录下的 Inbox 是系统放「用其他应用打开 / 隔空投送」副本的地方，不是用户的文件夹，
            // 导入完会清掉；不跳过的话收到文件的瞬间会闪出一个「Inbox」文件夹
            if ReceiveFilesLogic.isSystemInboxPath(relative) {
                enumerator.skipDescendants()
                continue
            }
            // 读不到属性的条目（刚被删、权限异常）跳过：下一轮重扫会补上，没必要中断整次遍历
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let created = values.creationDate
            let modified = values.contentModificationDate
            items.append(ScanItem(
                path: relative,
                isFolder: values.isDirectory ?? false,
                fileSize: Int64(values.fileSize ?? 0),
                createdAt: created ?? modified ?? Date(timeIntervalSince1970: 0),
                modifiedAt: modified ?? created ?? Date(timeIntervalSince1970: 0),
                // 本机文件永远在本机
                isDownloaded: true,
                downloadFraction: nil
            ))
        }
        return items
    }
}
