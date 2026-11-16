import Foundation

/// 本机缓存目录（`Caches/Kapi/`）。元数据和封面都放这里：
/// 可重建、不需要同步，系统空间紧张时会自己清，清了下次重新读就是了。
enum LocalCache {
    static let root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Kapi", directoryHint: .isDirectory)
    }()

    /// 取子目录并确保存在。系统清缓存可能把它整个删掉，所以每次用之前都确认一遍
    static func directory(_ name: String) -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        // 建失败（磁盘满）也只是这次没缓存，后面写文件时会各自失败，无需在这里报
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
