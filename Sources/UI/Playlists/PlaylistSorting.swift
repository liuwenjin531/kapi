import Foundation

/// 歌单页的视图形态（R1 列表 / R1b 方格），存 `@AppStorage`，只在本机生效
enum PlaylistViewMode: String, CaseIterable, Sendable {
    case list, grid

    var label: String { self == .list ? "列表" : "网格" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

/// 歌单页的排序（R1c）。`custom` 就是数组本身的顺序，其余只在显示时临时排、不改文件
enum PlaylistSortKey: String, CaseIterable, Sendable {
    case custom, name, dateAdded, lastPlayed

    var label: String {
        switch self {
        case .custom: "自定义顺序"
        case .name: "名称"
        case .dateAdded: "添加日期"
        case .lastPlayed: "上次播放日期"
        }
    }
}

enum PlaylistSorting {
    /// 名称从小到大（中文按拼音）；添加日期、上次播放日期从新到旧；从没播过的排最后。
    /// 同值时保持自定义顺序（`sorted` 不稳定，所以显式用原下标当次要键）
    static func sorted(_ playlists: [Playlist], by key: PlaylistSortKey) -> [Playlist] {
        guard key != .custom else { return playlists }
        let indexed = Array(playlists.enumerated())
        let ordered = indexed.sorted { a, b in
            let (x, y) = (a.element, b.element)
            switch key {
            case .custom:
                break
            case .name:
                let result = x.name.localizedStandardCompare(y.name)
                if result != .orderedSame { return result == .orderedAscending }
            case .dateAdded:
                if x.createdAt != y.createdAt { return x.createdAt > y.createdAt }
            case .lastPlayed:
                switch (x.lastPlayedAt, y.lastPlayedAt) {
                case let (p?, q?) where p != q: return p > q
                case (nil, .some): return false
                case (.some, nil): return true
                default: break
                }
            }
            return a.offset < b.offset
        }
        return ordered.map(\.element)
    }
}

extension Playlist {
    /// 「最爱」不是 `Playlist`，但详情页和导航都用歌单 id 当路由值，所以给它一个保留 id：
    /// 约定 `PlaylistDetailView(id: Playlist.favoritesID)` 显示最爱。真实歌单 id 是随机 UUID，不会撞上
    static let favoritesID = UUID(uuidString: "00000000-0000-0000-0000-00000000FA70") ?? UUID()
}
