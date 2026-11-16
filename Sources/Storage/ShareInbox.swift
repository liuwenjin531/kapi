import Foundation

/// 分享扩展和主 App 是两个进程，各有各的沙盒，唯一的交接点就是 App Group 共享容器：
/// 扩展把文件写进 Inbox，主 App 回到前台时搬走。
/// 本文件同时编进两个 target（`project.yml` 里 KapiShare 的 sources 要包含它），只依赖 Foundation。
enum ShareInbox {
    /// 组名从 Info.plist 的 `KapiAppGroup` 读，不在代码里写死；
    /// 读不到时退回正式组名（单元测试里没有这个键）
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "KapiAppGroup") as? String
        ?? "group.com.liuwenjin.kapi"

    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// 扩展侧：给一个文件开一个独占的目录。
    /// 不平铺是因为重名太常见（微信、相册里一堆 IMG_0001.MOV），平铺会互相覆盖，
    /// 而文件名要原样留着当曲目名
    static func makeSlot() -> URL? {
        guard let root else { return nil }
        let slot = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return slot
    }

    /// 主 App 侧：待搬运的文件
    static func pending() -> [URL] {
        slots().flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
    }

    /// 搬完一个文件后清掉它：连同它独占的目录一起删。
    /// 逐个清而不是整体清空，这样导入失败的文件会留在收件箱，下次回前台再试，不会无声丢掉
    static func remove(_ file: URL) {
        let slot = file.deletingLastPathComponent()
        // 只删收件箱里的东西，传进来的路径不在 Inbox 下就不动
        guard let root, slot.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        // 删不掉（已被删）无所谓，下次 pending() 不会再看到
        try? FileManager.default.removeItem(at: slot)
    }

    private static func slots() -> [URL] {
        guard let root else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }
}
