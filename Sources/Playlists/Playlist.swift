import Foundation

/// 一个歌单。对应 `Documents/.kapi/playlists.json` 里的一项。
struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    /// 封面图相对 `.kapi/` 的路径，如 `covers/<id>.jpg`；没有自定义封面为 nil
    var cover: String?
    /// 曲目主键（相对 `Documents/` 的路径），顺序就是播放顺序。
    /// 找不到的路径不删，显示时跳过：误删后再放回来，歌单能恢复
    var items: [String]
    var createdAt: Date
    var updatedAt: Date
    var lastPlayedAt: Date?
}

/// `playlists.json` 的整文件结构。数组顺序就是「自定义顺序」，排序菜单只在显示时临时排，不改文件
struct PlaylistsFile: Codable, Sendable {
    /// 当前认识的格式版本。读到比它大的文件只读不写，免得把新格式写坏
    static let currentVersion = 1

    var version: Int = PlaylistsFile.currentVersion
    var playlists: [Playlist] = []
}

/// `favorites.json` 的整文件结构。「最爱」固定排第一、不能删、不能改名，所以它不是 Playlist
struct FavoritesFile: Codable, Sendable {
    static let currentVersion = 1

    var version: Int = FavoritesFile.currentVersion
    var items: [String] = []
}

/// 带格式版本号的状态文件。`PlaylistStore` 用它统一判断「版本比本 App 新 → 只读」
protocol VersionedStateFile: Codable, Sendable {
    static var currentVersion: Int { get }
    init()
}

extension PlaylistsFile: VersionedStateFile {}
extension FavoritesFile: VersionedStateFile {}

/// 歌单 JSON 的统一编解码配置。日期用 ISO 8601，
/// 输出排好键序，这样 iCloud 同步时同样内容的文件字节一致，不会白白触发冲突
enum PlaylistCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
