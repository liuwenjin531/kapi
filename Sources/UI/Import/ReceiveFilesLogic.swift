import Foundation

/// 「收到文件」流程里的纯逻辑：合并批次、文件名列表截断、默认文件夹回退、收件目录清理的判断。
/// 单独成文件是为了不依赖界面就能写单元测试。
enum ReceiveFilesLogic {
    /// 系统「用其他应用打开 / 隔空投送」会把文件放进沙盒 `Documents/Inbox/`
    static let systemInboxName = "Inbox"

    // MARK: - 批次合并

    /// 把新来的 URL 合并进待处理列表，按「标准化后的路径」去重。
    /// 一次分享多个文件时系统会连续调多次 onOpenURL；回前台又会重读分享收件箱，
    /// 同一个文件可能被报多次，不去重的话列表里会出现重复项
    static func merge(_ existing: [URL], with incoming: [URL]) -> [URL] {
        var seen = Set(existing.map(key))
        var result = existing
        for url in incoming where seen.insert(key(url)).inserted {
            result.append(url)
        }
        return result
    }

    private static func key(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: - 文件名列表

    /// 列出的文件名最多显示 `limit` 个，其余折成「等 N 个」
    static func summarize(names: [String], limit: Int = 5) -> (shown: [String], more: Int) {
        guard names.count > limit else { return (names, 0) }
        return (Array(names.prefix(limit)), names.count - limit)
    }

    // MARK: - 目标文件夹

    /// 默认目标：上次选的文件夹；没记录或已经不存在就退回根目录（空串）
    static func initialFolder(saved: String?, exists: (String) -> Bool) -> String {
        guard let saved, !saved.isEmpty, exists(saved) else { return "" }
        return saved
    }

    /// 「放到」一行显示的路径：根目录叫「乐库」，子目录用「 › 」连
    static func folderTitle(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        return (["乐库"] + parts).joined(separator: " › ")
    }

    /// 记「上次选的文件夹」的 UserDefaults 键，两种乐库位置各存各的：
    /// 本机和 iCloud 的目录结构互不相干，混用会指到不存在的文件夹
    static func lastFolderKey(location: LibraryRoot.Location) -> String {
        "receiveFilesLastFolder.\(location.rawValue)"
    }

    // MARK: - 收件目录清理

    enum Origin: Equatable {
        /// 系统放进沙盒 `Documents/Inbox/` 的副本：用完必须删，否则本机模式下占着乐库根目录
        case systemInbox
        /// 分享扩展放进 App Group 收件箱的文件，由 `ShareInbox.remove` 清
        case shareInbox
        /// 别处原地打开的文件（「文件」App、iCloud 里的原件），绝不能删
        case external
    }

    /// 判断一个文件来自哪里。比较前统一解符号链接：模拟器和真机上 `/var` 与 `/private/var` 常混用
    static func origin(of url: URL, systemInbox: URL, shareInbox: URL?) -> Origin {
        // 比字符串路径而不是 URL：同一目录带不带末尾斜杠的两个 URL 不相等
        let dir = key(url.deletingLastPathComponent())
        if dir == key(systemInbox) { return .systemInbox }
        // 分享收件箱每个文件有独占的子目录：Inbox/<uuid>/文件
        if let shareInbox, key(url.deletingLastPathComponent().deletingLastPathComponent()) == key(shareInbox) {
            return .shareInbox
        }
        return .external
    }

    /// 一批文件处理完后该清掉哪些：系统 Inbox 里的副本不管成败都删（留着只会白占空间，
    /// 失败的界面上已经告诉用户了）；分享收件箱里失败的留着，下次回前台再试；别处的原件不动
    static func removable(all: [URL], failed: [URL], systemInbox: URL, shareInbox: URL?) -> [URL] {
        let failedKeys = Set(failed.map(key))
        return all.filter { url in
            switch origin(of: url, systemInbox: systemInbox, shareInbox: shareInbox) {
            case .systemInbox: true
            case .shareInbox: !failedKeys.contains(key(url))
            case .external: false
            }
        }
    }

    /// 乐库根目录下的 `Inbox`（含里面的东西）不算乐库内容
    static func isSystemInboxPath(_ relative: String) -> Bool {
        relative == systemInboxName || relative.hasPrefix(systemInboxName + "/")
    }
}
