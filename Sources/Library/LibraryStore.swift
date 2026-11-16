import Foundation
import Observation

/// 搜索结果里属于乐库的两组；歌单那一组由 `PlaylistStore` 出，界面层把三组拼起来
struct LibrarySearchResults: Sendable {
    var folders: [FolderNode] = []
    var tracks: [Track] = []
    var isEmpty: Bool { folders.isEmpty && tracks.isEmpty }
}

/// 乐库的内存模型：持有整棵文件夹树快照。
/// 由 `NSMetadataQuery` 的结果在后台建树，建好后回主线程整体替换 `root`（阶段 1）。
@Observable
@MainActor
final class LibraryStore {
    /// 根节点（名称「乐库」）。扫描完成前是一棵空树
    private(set) var root = FolderNode.build(from: [])
    /// 是否已经拿到过第一份扫描结果。界面用它区分「还在加载」和「乐库就是空的」
    private(set) var hasLoaded = false
    /// 正在下载的歌：主键 → 进度 0~1。只放正在下载的，下完就移除，列表行据此显示进度
    private(set) var downloadProgress: [String: Double] = [:]

    /// 取指定路径的文件夹；空串是根目录；找不到返回 nil（比如别的设备刚把它删了）
    func node(at path: String) -> FolderNode? {
        if path.isEmpty { return root }
        var current = root
        var walked = ""
        for part in path.split(separator: "/") {
            walked = walked.isEmpty ? String(part) : walked + "/" + part
            guard let next = current.subfolders.first(where: { $0.path == walked }) else { return nil }
            current = next
        }
        return current
    }

    /// 按主键找歌。歌单里存的是路径，显示时要还原成 Track
    func track(at path: String) -> Track? {
        let folder = (path as NSString).deletingLastPathComponent
        return node(at: folder)?.tracks.first { $0.path == path }
    }

    /// 搜文件夹名和歌名（不分大小写，包含即命中）。空查询返回空结果
    func search(_ query: String) -> LibrarySearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return LibrarySearchResults() }
        var result = LibrarySearchResults()
        func walk(_ node: FolderNode) {
            if !node.isRoot, node.name.localizedStandardContains(q) { result.folders.append(node) }
            result.tracks += node.tracks.filter { $0.title.localizedStandardContains(q) }
            node.subfolders.forEach(walk)
        }
        walk(root)
        return result
    }

    /// 用一份新的扫描结果整体替换树。扫描方（阶段 1）在后台建好树再调这里
    func replace(root newRoot: FolderNode) {
        root = newRoot
        hasLoaded = true
    }

    /// 切换乐库位置时清空：新位置的第一份扫描结果到之前，不能还显示旧那边的歌
    func reset() {
        root = FolderNode.build(from: [])
        hasLoaded = false
        downloadProgress = [:]
    }

    /// 更新下载进度。内容没变就不赋值，免得下载中每次推送都让整个列表重绘
    func updateDownloadProgress(_ progress: [String: Double]) {
        if downloadProgress != progress { downloadProgress = progress }
    }
}
