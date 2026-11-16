import Foundation

/// 一次文件操作造成的路径变化（重命名、移动）。路径都是相对 `Documents/` 的。
///
/// 歌单、最爱、歌词微调、播放队列都按路径存歌，文件被 App 自己改名 / 挪走之后要显式跟着改，
/// 不能靠「文件名 + 大小」认领——重命名后文件名变了，认领不到。
struct PathChange: Equatable, Sendable {
    let old: String
    let new: String
    /// 文件夹改名 / 移动：里面所有歌的路径前缀都要换
    let isFolder: Bool
}

enum PathMapping {
    /// 某条路径经过 `changes` 之后的新路径；不受影响返回 nil。
    /// 同一批变化里的源互不包含（批量操作选的都是同一层的项），所以取第一个命中的就行。
    /// 前缀要带「/」比较：改名「华语」不能误伤「华语2/歌.mp3」
    static func mapped(_ path: String, by changes: [PathChange]) -> String? {
        for change in changes {
            if path == change.old { return change.new }
            if change.isFolder, path.hasPrefix(change.old + "/") {
                return change.new + path.dropFirst(change.old.count)
            }
        }
        return nil
    }

    /// 在 `candidates`（相对路径）里挑出受 `changes` 影响的，给「队列 / 歌单里有没有受影响的歌」用
    static func affected(_ paths: some Sequence<String>, by changes: [PathChange]) -> [String: String] {
        var result: [String: String] = [:]
        for path in paths {
            if let new = mapped(path, by: changes) { result[path] = new }
        }
        return result
    }
}
