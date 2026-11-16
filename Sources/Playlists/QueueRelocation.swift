import Foundation

/// 播放队列里的曲目被用户在「文件」App 里挪了位置后，算出「旧路径 → 新 Track」的换新表，
/// 交给 `PlayerService.relocate(_:)`。
///
/// 做法和歌单认领（`PlaylistStore.relocate`）同一套保守规则：只处理「旧路径已不在乐库里」的曲目，
/// 用「文件名 + 文件大小」在现有曲目里找，**恰好一个**才认领；有多个候选、或两条旧路径指向同一个新路径，
/// 都不动——认错比认不出更糟（认错会让锁屏和队列显示成另一首歌）。
enum QueueRelocation {
    static func moves(queue: [Track], live tracks: [Track]) -> [String: Track] {
        let live = Set(tracks.map(\.path))
        let orphans = queue.filter { !live.contains($0.path) }
        guard !orphans.isEmpty else { return [:] }

        struct Key: Hashable { let name: String; let size: Int64 }
        var index: [Key: [Track]] = [:]
        for track in tracks {
            index[Key(name: track.fileName, size: track.fileSize), default: []].append(track)
        }

        var claims: [String: Track] = [:]
        for old in orphans {
            let hits = index[Key(name: old.fileName, size: old.fileSize)] ?? []
            if hits.count == 1 { claims[old.path] = hits[0] }
        }
        let targetCount = Dictionary(claims.values.map { ($0.path, 1) }, uniquingKeysWith: +)
        return claims.filter { targetCount[$0.value.path] == 1 }
    }
}
