import Foundation

/// 乐库文件夹树的一个节点。整棵树是值类型，每次扫描整体重建、整体替换，
/// 这样界面拿到的永远是一份自洽的快照，不会读到建到一半的树。
struct FolderNode: Identifiable, Hashable, Sendable {
    /// 相对 `Documents/` 的路径，根目录为空串
    let path: String
    /// 显示名。根目录固定叫「乐库」，其余取路径最后一段
    let name: String
    /// 直接子文件夹，已按名称排好
    var subfolders: [FolderNode]
    /// 直接放在本文件夹里的歌（不含子文件夹），已按文件名排好
    var tracks: [Track]

    var id: String { path }
    var isRoot: Bool { path.isEmpty }

    /// 本文件夹及其所有子孙里的歌曲数（递归）
    var trackCount: Int {
        tracks.count + subfolders.reduce(0) { $0 + $1.trackCount }
    }

    /// 本文件夹及其所有子孙里的文件总字节数（递归）
    var totalSize: Int64 {
        tracks.reduce(0) { $0 + $1.fileSize } + subfolders.reduce(0) { $0 + $1.totalSize }
    }

    /// 递归展开成一维曲目列表：先本层的歌，再依次进各子文件夹。「播放 / 随机」整个文件夹时用
    var allTracks: [Track] {
        tracks + subfolders.flatMap(\.allTracks)
    }

    /// 2×2 拼图封面要用的曲目：按 `allTracks` 的顺序取前 `limit` 首。
    /// 只返回曲目，不在这里读封面图——读图是慢操作，由界面层走缓存异步取。
    func coverTracks(limit: Int = 4) -> [Track] {
        var result: [Track] = []
        collectCoverTracks(into: &result, limit: limit)
        return result
    }

    private func collectCoverTracks(into result: inout [Track], limit: Int) {
        for track in tracks where result.count < limit { result.append(track) }
        for sub in subfolders where result.count < limit {
            sub.collectCoverTracks(into: &result, limit: limit)
        }
    }

    /// 由扫描结果建树。`folderPaths` 用来保留没有歌的空文件夹（用户刚新建的），
    /// 只靠曲目路径推不出它们。路径都是相对 `Documents/`、以 `/` 分隔。
    static func build(from tracks: [Track], folderPaths: [String] = []) -> FolderNode {
        var tracksByFolder: [String: [Track]] = [:]
        var children: [String: Set<String>] = [:]

        /// 把一条文件夹路径的每一级都登记到它的父级下面
        func register(folder: String) {
            var current = folder
            while !current.isEmpty {
                let parent = current.contains("/")
                    ? String(current[..<current.lastIndex(of: "/")!])
                    : ""
                children[parent, default: []].insert(current)
                current = parent
            }
        }

        for track in tracks {
            tracksByFolder[track.folderPath, default: []].append(track)
            register(folder: track.folderPath)
        }
        for folder in folderPaths { register(folder: folder) }

        func make(_ path: String) -> FolderNode {
            let name = path.isEmpty ? "乐库" : String((path as NSString).lastPathComponent)
            let subs = (children[path] ?? []).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }.map(make)
            let own = (tracksByFolder[path] ?? []).sorted {
                $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
            return FolderNode(path: path, name: name, subfolders: subs, tracks: own)
        }
        return make("")
    }
}
