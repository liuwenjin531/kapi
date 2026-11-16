import Foundation

/// 一首歌。值类型，只描述「文件系统里有什么」，不带播放状态。
///
/// 主键是相对 iCloud 容器 `Documents/` 的路径（如 `华语/怀旧/夜航船.flac`）：
/// 用户在「文件」App 里挪动、改名后路径会变，歌单和最爱靠「文件名 + 文件大小」重新认领。
struct Track: Identifiable, Hashable, Sendable {
    /// 相对 `Documents/` 的路径，用 `/` 分隔，不以 `/` 开头
    let path: String
    /// 本机上的文件 URL。没下载的文件在 iCloud 容器里是占位项，URL 依然有效，
    /// 但读内容前要先下载（`isDownloaded == false` 时不要读标签，会触发整首下载）
    let url: URL
    /// 标题。没读过标签（或没下载）时用去掉扩展名的文件名
    var title: String
    /// 艺人。没读到时为 nil；列表上不显示，播放页和锁屏才用
    var artist: String?
    /// 秒。没读到时为 0
    var duration: TimeInterval
    /// 字节数
    var fileSize: Int64
    /// 大写扩展名，如 `MP3`、`FLAC`，列表上的格式小胶囊直接用
    var format: String
    /// 是否有视频轨（MV）。没读过元数据时按扩展名（mp4 / m4v / mov）猜
    var hasVideo: Bool
    /// 视频宽高比（宽 / 高），非视频为 nil
    var videoAspect: Double?
    /// 文件创建时间，「添加日期」排序用
    var createdAt: Date
    /// 内容是否已在本机。没下载的点了要先下载再播
    var isDownloaded: Bool
    /// 文件内容修改时间。和路径、体积一起组成元数据 / 封面缓存的键。
    /// 放在最后并给默认值，已有的成员逐一初始化调用不受影响
    var modifiedAt: Date = Date(timeIntervalSince1970: 0)

    var id: String { path }

    /// 所在文件夹的相对路径，根目录为空串
    var folderPath: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// 带扩展名的文件名，「文件名 + 文件大小」认领旧路径时用
    var fileName: String { (path as NSString).lastPathComponent }
}
