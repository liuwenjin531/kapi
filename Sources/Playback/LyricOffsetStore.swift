import Foundation
import Observation

/// 一首歌的歌词时间微调。`offsetMs` 为正表示歌词提前出现，为负表示延后（和 LRC 的 `[offset:]` 同向）。
/// 带上文件大小，是为了歌被挪动后能按「文件名 + 文件大小」认领回来，和歌单同一套规矩
struct LyricOffsetEntry: Codable, Hashable, Sendable {
    var path: String
    var size: Int64
    var offsetMs: Int
}

/// `Documents/.kapi/lyric-offsets.json` 的整文件结构。只存非零的条目，调回 0 就删掉
struct LyricOffsetsFile: VersionedStateFile {
    static let currentVersion = 1

    var version: Int = LyricOffsetsFile.currentVersion
    var entries: [LyricOffsetEntry] = []
}

/// 每首歌的歌词时间微调，落在 iCloud 里，换设备也在。
///
/// 为什么不直接改用户的 `.lrc`：那是用户自己的文件，别的软件也在用，改了不好还原；
/// 文件还没下载时也改不了。所以偏移单独存，叠在 LRC 自带的 `[offset:]` 之上。
///
/// 读写规则同 `PlaylistStore`：走 `StateFile`（协调读写、占位拦截、冲突处理），
/// 每次修改前重读最新文件，版本比本 App 新时只读不写
@Observable
@MainActor
final class LyricOffsetStore {
    /// 微调范围上下限（毫秒）。再大就不是「差一点」而是歌词对错了歌
    static let limitMs = 10_000

    /// 曲目主键 → 偏移毫秒。只含非零项
    private(set) var offsets: [String: Int] = [:]
    private(set) var isReadOnly = false

    @ObservationIgnored private var file: URL?

    /// 指向 `Documents/`。换了存储位置时先清空内存再读，免得残留旧库的数据
    func attach(documentsURL: URL) {
        file = documentsURL.appending(path: ".kapi", directoryHint: .isDirectory)
            .appending(path: "lyric-offsets.json")
        offsets = [:]
        isReadOnly = false
        reload()
    }

    /// 回到前台时重读。读不到就保留内存里现有的，不清空
    func reload() {
        guard let file, let disk = try? Self.readDisk(file) else { return }
        adopt(disk)
    }

    func offsetMs(for path: String) -> Int { offsets[path] ?? 0 }

    /// 设定某首歌的偏移（毫秒，超出范围夹住）。设为 0 就移除记录
    func setOffset(_ milliseconds: Int, for track: Track) throws(PlaylistError) {
        guard let file else { throw .notAttached }
        StateFile.resolveConflicts(at: file)
        var disk = try Self.readDisk(file)
        adopt(disk)
        if disk.newer { throw .readOnly }

        let value = min(max(milliseconds, -Self.limitMs), Self.limitMs)
        disk.value.entries.removeAll { $0.path == track.path }
        if value != 0 {
            disk.value.entries.append(LyricOffsetEntry(path: track.path, size: track.fileSize, offsetMs: value))
        }
        // 排好序再写：同样的内容字节一致，iCloud 同步时不会白白触发冲突
        disk.value.entries.sort { $0.path < $1.path }
        try PlaylistStore.writeFile(disk.value, to: file)
        adopt(disk)
    }

    /// 每次扫描完成后调用：旧路径不在乐库里的，按「文件名 + 文件大小」认领到新路径。
    /// 这是后台顺带的校正，读不到、只读、写失败都静默跳过，下次扫描再试
    func relocate(using tracks: [Track]) {
        guard let file, !offsets.isEmpty else { return }
        StateFile.resolveConflicts(at: file)
        guard var disk = try? Self.readDisk(file) else { return }
        adopt(disk)
        guard !disk.newer else { return }
        let moved = Self.relocated(disk.value.entries, live: tracks)
        guard moved != disk.value.entries else { return }
        disk.value.entries = moved
        guard (try? PlaylistStore.writeFile(disk.value, to: file)) != nil else { return }
        adopt(disk)
    }

    /// 用户在 App 里重命名或移动了歌 / 文件夹：显式把微调记录的旧路径改成新路径（规则同 `PlaylistStore.applyMoves`）。
    /// 只读 / 还在同步 / 读不到时抛错由调用方提示；没有受影响的记录不写盘
    func applyMoves(_ changes: [PathChange]) throws(PlaylistError) {
        guard let file else { throw .notAttached }
        guard !changes.isEmpty, !offsets.isEmpty else { return }
        StateFile.resolveConflicts(at: file)
        var disk = try Self.readDisk(file)
        adopt(disk)
        if disk.newer { throw .readOnly }
        let moved = Self.remapped(disk.value.entries, by: changes)
        guard moved != disk.value.entries else { return }
        disk.value.entries = moved
        try PlaylistStore.writeFile(disk.value, to: file)
        adopt(disk)
    }

    /// 路径替换的纯逻辑。改完后同一路径有多条记录时留第一条；排好序，同样内容字节一致
    nonisolated static func remapped(_ entries: [LyricOffsetEntry], by changes: [PathChange]) -> [LyricOffsetEntry] {
        var seen = Set<String>()
        var output: [LyricOffsetEntry] = []
        for entry in entries {
            var moved = entry
            if let target = PathMapping.mapped(entry.path, by: changes) { moved.path = target }
            if seen.insert(moved.path).inserted { output.append(moved) }
        }
        return output.sorted { $0.path < $1.path }
    }

    /// 认领的纯逻辑，规则同歌单：只处理旧路径已不在乐库里的条目；同名同大小**恰好一个**才认领；
    /// 两条旧路径指向同一个新路径、或新路径上已经有自己的记录，都不动——认错比认不出更糟
    nonisolated static func relocated(_ entries: [LyricOffsetEntry], live tracks: [Track]) -> [LyricOffsetEntry] {
        let livePaths = Set(tracks.map(\.path))
        struct Key: Hashable { let name: String; let size: Int64 }
        var index: [Key: [String]] = [:]
        for track in tracks {
            index[Key(name: track.fileName, size: track.fileSize), default: []].append(track.path)
        }

        let existing = Set(entries.map(\.path))
        var claims: [String: String] = [:]
        for entry in entries where !livePaths.contains(entry.path) {
            let name = (entry.path as NSString).lastPathComponent
            let hits = index[Key(name: name, size: entry.size)] ?? []
            if hits.count == 1, !existing.contains(hits[0]) { claims[entry.path] = hits[0] }
        }
        let targetCount = Dictionary(claims.values.map { ($0, 1) }, uniquingKeysWith: +)
        let accepted = claims.filter { targetCount[$0.value] == 1 }
        guard !accepted.isEmpty else { return entries }

        return entries
            .map { entry in
                var moved = entry
                if let target = accepted[entry.path] { moved.path = target }
                return moved
            }
            .sorted { $0.path < $1.path }
    }

    // MARK: 内部

    private struct Disk {
        var value: LyricOffsetsFile
        var newer: Bool
    }

    private static func readDisk(_ file: URL) throws(PlaylistError) -> Disk {
        let read = try PlaylistStore.readFile(LyricOffsetsFile.self, at: file)
        return Disk(value: read.value, newer: read.newer)
    }

    private func adopt(_ disk: Disk) {
        offsets = Dictionary(disk.value.entries.map { ($0.path, $0.offsetMs) }, uniquingKeysWith: { _, last in last })
        isReadOnly = disk.newer
    }
}
