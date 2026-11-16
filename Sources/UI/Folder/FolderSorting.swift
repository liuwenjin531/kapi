import Foundation

/// 文件夹页的视图形态。所有文件夹页共用一个设置，存 `@AppStorage`
enum FolderViewMode: String, CaseIterable, Sendable {
    case list, grid

    var label: String { self == .list ? "列表" : "网格" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

/// 文件夹页的排序键
enum FolderSortKey: String, CaseIterable, Sendable {
    case name, dateAdded, type, size

    var label: String {
        switch self {
        case .name: "名称"
        case .dateAdded: "添加日期"
        case .type: "类型"
        case .size: "大小"
        }
    }
}

/// 排序规则。纯函数，方便单测；界面只管把结果画出来。
///
/// 方向是固定的、不让用户再选一次：名称 / 类型从小到大，添加日期 / 大小从新到旧、从大到小——
/// 这两项用户几乎总是想先看最新、最大的。
enum FolderSorting {
    /// 名称用 `localizedStandardCompare`：「2」排在「10」前面，中文按拼音
    private static func byName(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    static func tracks(_ tracks: [Track], by key: FolderSortKey) -> [Track] {
        tracks.sorted { a, b in
            switch key {
            case .name:
                break
            case .dateAdded:
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            case .type:
                if a.format != b.format { return a.format.localizedStandardCompare(b.format) == .orderedAscending }
            case .size:
                if a.fileSize != b.fileSize { return a.fileSize > b.fileSize }
            }
            // 主键相同（或按名称排）时一律回到名称，路径兜底，保证顺序稳定、不随刷新抖动
            if a.title != b.title { return byName(a.title, b.title) }
            return a.path < b.path
        }
    }

    /// 文件夹没有「添加日期」和「类型」，这两项下按名称排；只有「大小」有意义
    static func folders(_ folders: [FolderNode], by key: FolderSortKey) -> [FolderNode] {
        folders.sorted { a, b in
            if key == .size, a.totalSize != b.totalSize { return a.totalSize > b.totalSize }
            if a.name != b.name { return byName(a.name, b.name) }
            return a.path < b.path
        }
    }
}
