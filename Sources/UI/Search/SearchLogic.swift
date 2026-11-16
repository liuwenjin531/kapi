import Foundation

/// 搜索页的纯逻辑：最近搜索的增删、歌单名匹配、路径文字。界面之外单独放，方便单测。
enum SearchLogic {
    static let maxRecents = 10

    /// 去掉首尾空白；空串返回 nil
    static func normalized(_ query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : q
    }

    /// 把一条搜索记到最近搜索最前面：已有的（不分大小写）先移除再放前，最多保留 `maxRecents` 条
    static func adding(_ query: String, to recents: [String]) -> [String] {
        guard let q = normalized(query) else { return recents }
        var list = recents.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        return Array(list.prefix(maxRecents))
    }

    /// 最近搜索存成一个字符串放进 `@AppStorage`；查询词里不会有换行（输入框单行），用换行分隔最省事
    static func decode(_ stored: String) -> [String] {
        stored.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func encode(_ recents: [String]) -> String {
        recents.joined(separator: "\n")
    }

    /// 歌单名包含查询词即命中（不分大小写、变音符号）
    static func matchingPlaylists(_ playlists: [Playlist], query: String) -> [Playlist] {
        guard let q = normalized(query) else { return [] }
        return playlists.filter { $0.name.localizedStandardContains(q) }
    }

    /// 文件夹的路径文字：「华语 › 怀旧」，根目录写「乐库」
    static func pathText(_ folderPath: String) -> String {
        folderPath.isEmpty ? "乐库" : folderPath.split(separator: "/").joined(separator: " › ")
    }

    /// 从最近搜索里删一条（不分大小写）
    static func removing(_ query: String, from recents: [String]) -> [String] {
        recents.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
    }
}

/// 搜索结果的分类筛选（内屏横放左栏）：全部 / 歌单 / 文件夹 / 歌曲
enum SearchCategory: CaseIterable, Hashable, Sendable {
    case all, playlists, folders, tracks

    var label: String {
        switch self {
        case .all: "全部"
        case .playlists: "歌单"
        case .folders: "文件夹"
        case .tracks: "歌曲"
        }
    }

    var symbol: String {
        switch self {
        case .all: "magnifyingglass"
        case .playlists: "music.note.list"
        case .folders: "folder"
        case .tracks: "music.note"
        }
    }

    /// 选了这个分类后，某一组结果要不要显示。「全部」三组都显示
    func shows(_ section: SearchCategory) -> Bool {
        self == .all || self == section
    }
}

/// 三组结果的个数，用来给分类筛选标数字
struct SearchCounts: Equatable, Sendable {
    var playlists = 0
    var folders = 0
    var tracks = 0

    var all: Int { playlists + folders + tracks }

    func count(for category: SearchCategory) -> Int {
        switch category {
        case .all: all
        case .playlists: playlists
        case .folders: folders
        case .tracks: tracks
        }
    }
}
