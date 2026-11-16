import Foundation

/// 歌单、最爱、封面这类状态文件的读写。
///
/// 文件在 iCloud 容器里时，可能只是个占位（内容还在云上）。这时读出来是空的，
/// 拿空内容当真、再写回去，就会把另一台设备上的歌单整份冲掉。
/// 所以读要分清「确实没有这个文件」和「暂时读不到」，后者绝不能写。
enum StateFile {
    enum Read {
        /// 确实没有这个文件，可以新建
        case missing
        /// 文件在，但现在读不到（iCloud 还没下载完，或正被别处写着）。这时绝不能写
        case unavailable
        case loaded(Data)
    }

    static func read(_ url: URL) -> Read {
        let fm = FileManager.default
        // 旧式占位：同目录下的 `.名字.icloud`，真文件还没下载
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        if fm.fileExists(atPath: placeholder.path(percentEncoded: false)) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            return .unavailable
        }
        guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { return .missing }
        // 新式占位：文件名照旧，但内容还在云上。顺手让系统开始下载，下次刷新就能读到
        if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
           status == .notDownloaded {
            try? fm.startDownloadingUbiquitousItem(at: url)
            return .unavailable
        }
        var result: Read = .unavailable
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { target in
            if let data = try? Data(contentsOf: target) { result = .loaded(data) }
        }
        return result
    }

    /// 整文件覆盖写入。写之前先处理 iCloud 冲突（见 `resolveConflicts`）。
    /// 失败时抛出，调用方据此决定内存要不要跟着改
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        resolveConflicts(at: url)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    /// 两台设备同时改、iCloud 产生了冲突副本时，保留修改时间最新的那一份，其余标记已解决并删除。
    /// 「最新」按修改时间判断，用户已接受「同时改会有小概率丢一次修改」，不做分设备合并。
    static func resolveConflicts(at url: URL) {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty else { return }
        let newest = conflicts.max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
        let current = NSFileVersion.currentVersionOfItem(at: url)
        let currentDate = current?.modificationDate ?? .distantPast
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &error) { target in
            // 当前文件不是最新的那份：先用最新的覆盖当前文件，再丢弃所有冲突版本
            if let newest, (newest.modificationDate ?? .distantPast) > currentDate {
                _ = try? newest.replaceItem(at: target)
            }
            for version in conflicts {
                version.isResolved = true
                try? version.remove()
            }
        }
    }
}
