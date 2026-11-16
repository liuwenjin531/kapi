import Foundation
import ImageIO
import Observation

/// 歌单操作可能的失败。界面层统一转成提示文案
enum PlaylistError: Error, Equatable {
    /// 状态文件还在云上、没下载到本机：不写，提示「歌单还在同步」
    case stillSyncing
    /// 文件格式版本比本 App 新：只读不写
    case readOnly
    /// 找不到指定歌单
    case notFound
    /// 还没有 `attach` 到 Documents，没有可写的位置
    case notAttached
    /// 文件内容解不开（格式坏了）。不写，免得把它整份覆盖掉
    case unreadable
    /// 写盘失败（磁盘满、容器权限等）
    case writeFailed
}

/// 歌单与最爱的模型，同时负责落盘。
///
/// 落盘规则：读写都走 `NSFileCoordinator`，整文件覆盖；
/// **每次修改前先重新读一次最新文件**，在最新内容上改，避免用本机的旧内存冲掉另一台设备的修改。
/// 内存里的 `playlists` / `favorites` 只是磁盘内容的镜像，每次读写后都以磁盘为准刷新。
@Observable
@MainActor
final class PlaylistStore {
    /// 自定义顺序的歌单（不含「最爱」）
    private(set) var playlists: [Playlist] = []
    /// 最爱的曲目主键，加入顺序
    private(set) var favorites: [String] = []
    /// 文件版本比本 App 新时为 true，此时所有写操作抛 `.readOnly`
    private(set) var isReadOnly = false

    /// `Documents/.kapi/`。`attach` 之前为 nil
    @ObservationIgnored private var stateDir: URL?
    /// `relocate` 用：路径 → 最近一次扫描看到的文件大小。只存在内存里、不落盘，也不进 JSON。
    /// 冷启动后这张表是空的，所以「冷启动前就已挪走」的文件认领不了，只能等它在本次运行中被扫到过
    @ObservationIgnored private var knownSizes: [String: Int64] = [:]
    /// 路径 → 大小表落盘的位置（本机 `Caches/Kapi/relocate-sizes.json`）。
    /// 不放 iCloud、不进歌单 JSON：它只是本机上次扫描的记忆，丢了最多少认领一次
    @ObservationIgnored private var sizesFile: URL

    /// 测试时传临时文件，免得污染真实缓存目录
    init(sizesFile: URL = LocalCache.root.appending(path: "relocate-sizes.json")) {
        self.sizesFile = sizesFile
    }

    // MARK: 挂载与重读

    /// 指向 `Documents/`，读 `.kapi/playlists.json` 与 `favorites.json`。文件不存在就当空。
    /// 换了一个 Documents（比如切换存储位置）时，先清空内存再读，免得残留旧库的歌单
    /// - `sizesFile`：认领表放哪。本机和 iCloud 两套乐库各用一份，同名路径的歌大小不同，混用会认错
    func attach(documentsURL: URL, sizesFile: URL? = nil) {
        if let sizesFile { self.sizesFile = sizesFile }
        stateDir = documentsURL.appending(path: ".kapi", directoryHint: .isDirectory)
        playlists = []
        favorites = []
        isReadOnly = false
        // 读回上次运行记下的大小：这样「App 没开着时被挪走」的文件，下次启动也认领得回来
        knownSizes = Self.loadSizes(from: self.sizesFile)
        reload()
    }

    /// 回到前台、或收到外部变化时调用，重读磁盘。文件暂时读不到时保留内存里现有的内容，不清空
    func reload() {
        guard let disk = try? readDisk() else { return }
        adopt(disk)
    }

    // MARK: 歌单

    /// 新建空歌单，追加到自定义顺序末尾
    @discardableResult
    func create(name: String) throws(PlaylistError) -> Playlist {
        var disk = try readForWrite()
        let now = Date()
        let playlist = Playlist(id: UUID(), name: name, cover: nil, items: [],
                                createdAt: now, updatedAt: now, lastPlayedAt: nil)
        disk.lists.playlists.append(playlist)
        try commitLists(disk)
        return playlist
    }

    func rename(_ id: Playlist.ID, to name: String) throws(PlaylistError) {
        try mutate(id) { $0.name = name }
    }

    /// 删除歌单。歌单的封面文件一并删掉（删不掉也不影响结果，孤儿文件无害）
    func delete(_ id: Playlist.ID) throws(PlaylistError) {
        var disk = try readForWrite()
        guard let index = disk.lists.playlists.firstIndex(where: { $0.id == id }) else { throw .notFound }
        let removed = disk.lists.playlists.remove(at: index)
        try commitLists(disk)
        if let cover = removed.cover {
            try? FileManager.default.removeItem(at: disk.dir.appending(path: cover))
        }
    }

    /// 换封面。`imageData` 是任意格式的图片数据，转成最长边 1024 的 JPEG 写到 `.kapi/covers/<id>.jpg`；
    /// 传 nil 表示恢复默认封面，并删掉封面文件。
    /// 顺序是先写图片、再改 JSON：中途失败最多留下一个没人引用的图片，不会出现 JSON 指向不存在的图
    func setCover(_ id: Playlist.ID, imageData: Data?) throws(PlaylistError) {
        var disk = try readForWrite()
        guard let index = disk.lists.playlists.firstIndex(where: { $0.id == id }) else { throw .notFound }
        let relative = "covers/\(id.uuidString).jpg"
        let file = disk.dir.appending(path: relative)
        if let imageData {
            guard let jpeg = Self.makeCoverJPEG(from: imageData) else { throw .unreadable }
            try Self.writeData(jpeg, to: file)
            disk.lists.playlists[index].cover = relative
        } else {
            disk.lists.playlists[index].cover = nil
        }
        disk.lists.playlists[index].updatedAt = Date()
        try commitLists(disk)
        if imageData == nil {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 拖动调整歌单之间的顺序，语义同 SwiftUI `onMove`。数组顺序就是「自定义顺序」。
    /// 歌单页的编辑模式用；下标越界时不做任何改动
    func movePlaylists(from source: IndexSet, to destination: Int) throws(PlaylistError) {
        var disk = try readForWrite()
        let lists = disk.lists.playlists
        guard destination >= 0, destination <= lists.count, source.allSatisfy({ $0 < lists.count }) else { return }
        let moving = source.map { lists[$0] }
        var rest = lists.indices.filter { !source.contains($0) }.map { lists[$0] }
        rest.insert(contentsOf: moving, at: destination - source.filter { $0 < destination }.count)
        disk.lists.playlists = rest
        try commitLists(disk)
    }

    // MARK: 歌曲

    /// 加歌，追加到末尾；已在歌单里的跳过（包括同一批里重复的）
    func add(_ paths: [String], to id: Playlist.ID) throws(PlaylistError) {
        try mutate(id) { list in
            var seen = Set(list.items)
            for path in paths where seen.insert(path).inserted {
                list.items.append(path)
            }
        }
    }

    /// 删歌。越界的下标忽略，不会崩
    func remove(at offsets: IndexSet, from id: Playlist.ID) throws(PlaylistError) {
        try mutate(id) { list in
            let count = list.items.count
            let drop = Set(offsets.filter { $0 < count })
            list.items = list.items.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
    }

    /// 拖动排序，语义同 SwiftUI `onMove`（不依赖 SwiftUI，免得模型层跟着 UI 框架走）。
    /// 下标越界时不做任何改动
    func move(from source: IndexSet, to destination: Int, in id: Playlist.ID) throws(PlaylistError) {
        try mutate(id) { list in
            let items = list.items
            guard destination >= 0, destination <= items.count, source.allSatisfy({ $0 < items.count }) else { return }
            let moving = source.map { items[$0] }
            var rest = items.indices.filter { !source.contains($0) }.map { items[$0] }
            // 目标位置以原数组为准：被拿走的、排在目标之前的几条，要从目标下标里扣掉
            let insertAt = destination - source.filter { $0 < destination }.count
            rest.insert(contentsOf: moving, at: insertAt)
            list.items = rest
        }
    }

    /// 记下最近播放时间。播放不算歌单内容修改，所以不刷新 `updatedAt`。
    /// 这是播放过程中的顺带动作，读不到、只读或找不到歌单时静默跳过，不打断播放
    func markPlayed(_ id: Playlist.ID) {
        guard var disk = try? readForWrite(),
              let index = disk.lists.playlists.firstIndex(where: { $0.id == id }) else { return }
        disk.lists.playlists[index].lastPlayedAt = Date()
        try? commitLists(disk)
    }

    // MARK: 最爱

    func toggleFavorite(_ path: String) throws(PlaylistError) {
        var disk = try readForWrite()
        if let index = disk.favorites.items.firstIndex(of: path) {
            disk.favorites.items.remove(at: index)
        } else {
            disk.favorites.items.append(path)
        }
        try commitFavorites(disk)
    }

    func isFavorite(_ path: String) -> Bool {
        favorites.contains(path)
    }

    // MARK: 路径认领

    /// 文件被挪进、挪出子目录或改名之后，歌单和最爱里存的旧路径就找不到了。
    /// 对每条找不到的旧路径，用「文件名 + 文件大小」在 `tracks` 里认领新路径：
    /// - 旧路径的大小取自之前某次扫描看到的值（见 `knownSizes`），这次扫不到它，只能靠记下的大小；
    /// - 同名同大小在库里只有一个才认领，有多个就不动，认错比认不出更糟；
    /// - 找不到的条目一律保留，不删。
    /// 每次扫描完成后调用。没有需要改的时不写盘
    func relocate(using tracks: [Track]) {
        // 先记下这次看到的大小。认领用的是「之前」的表，所以本次新看到的路径也能在下次被认领
        var sizesChanged = false
        for track in tracks where knownSizes[track.path] != track.fileSize {
            knownSizes[track.path] = track.fileSize
            sizesChanged = true
        }
        // 没变就不写：每次扫描都落一次盘没有意义
        if sizesChanged { Self.saveSizes(knownSizes, to: sizesFile) }
        guard var disk = try? readForWrite() else { return }

        let live = Set(tracks.map(\.path))
        var index: [FileKey: [String]] = [:]
        for track in tracks {
            index[FileKey(name: track.fileName, size: track.fileSize), default: []].append(track.path)
        }

        let referenced = Set(disk.lists.playlists.flatMap(\.items) + disk.favorites.items)
        var claims: [String: String] = [:]
        for old in referenced where !live.contains(old) {
            guard let size = knownSizes[old] else { continue }
            let name = (old as NSString).lastPathComponent
            let hits = index[FileKey(name: name, size: size)] ?? []
            if hits.count == 1 { claims[old] = hits[0] }
        }
        // 两条旧路径认领到同一个新路径，说明判断有歧义，两条都不动
        let targetCount = Dictionary(claims.values.map { ($0, 1) }, uniquingKeysWith: +)
        let accepted = claims.filter { targetCount[$0.value] == 1 }
        guard !accepted.isEmpty else { return }

        // 改写后可能出现重复（认领到的新路径本来就在同一个歌单里），保留第一次出现的
        func rewrite(_ items: [String]) -> [String] {
            var seen = Set<String>()
            var output: [String] = []
            for item in items {
                let target = accepted[item] ?? item
                if seen.insert(target).inserted { output.append(target) }
            }
            return output
        }

        var listsChanged = false
        for i in disk.lists.playlists.indices {
            let before = disk.lists.playlists[i].items
            let after = rewrite(before)
            if after != before {
                disk.lists.playlists[i].items = after
                listsChanged = true
            }
        }
        let favoritesBefore = disk.favorites.items
        let favoritesAfter = rewrite(favoritesBefore)
        let favoritesChanged = favoritesAfter != favoritesBefore
        disk.favorites.items = favoritesAfter

        // 认领只是校正路径，不算用户修改，不刷新 updatedAt
        do {
            if listsChanged {
                try Self.writeFile(disk.lists, to: disk.dir.appending(path: "playlists.json"))
            }
            if favoritesChanged {
                try Self.writeFile(disk.favorites, to: disk.dir.appending(path: "favorites.json"))
            }
        } catch {
            reload()
            return
        }
        adopt(disk)
    }

    // MARK: 路径跟随（App 里改名 / 移动）

    /// 用户在 App 里重命名或移动了歌 / 文件夹：把歌单和最爱里存的旧路径显式改成新路径。
    /// 和 `relocate` 不同，这里不靠「文件名 + 大小」猜——改名后文件名变了，猜不到；这里是确切知道的。
    /// 文件夹改名 / 移动时，里面所有歌的路径前缀一并替换。没有受影响的就不写盘；
    /// 只读 / 还在同步 / 读不到时抛错，由调用方提示（文件已经改了，歌单这边之后只能靠用户重新加）。
    /// 路径校正不算用户编辑歌单，不刷新 `updatedAt`
    func applyMoves(_ changes: [PathChange]) throws(PlaylistError) {
        guard !changes.isEmpty else { return }
        var disk = try readForWrite()
        var listsChanged = false
        for i in disk.lists.playlists.indices {
            let before = disk.lists.playlists[i].items
            let after = Self.remapped(before, by: changes)
            if after != before {
                disk.lists.playlists[i].items = after
                listsChanged = true
            }
        }
        let favoritesAfter = Self.remapped(disk.favorites.items, by: changes)
        let favoritesChanged = favoritesAfter != disk.favorites.items
        disk.favorites.items = favoritesAfter
        if listsChanged { try Self.writeFile(disk.lists, to: disk.dir.appending(path: "playlists.json")) }
        if favoritesChanged { try Self.writeFile(disk.favorites, to: disk.dir.appending(path: "favorites.json")) }
        adopt(disk)
    }

    /// 路径替换的纯逻辑：按顺序换路径，换出重复项（新路径本来就在表里）只留第一次出现的
    nonisolated static func remapped(_ items: [String], by changes: [PathChange]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for item in items {
            let target = PathMapping.mapped(item, by: changes) ?? item
            if seen.insert(target).inserted { output.append(target) }
        }
        return output
    }

    // MARK: 认领表落盘

    /// 读不到、解不开都当空表：这张表只是优化，坏了不影响歌单本身
    nonisolated static func loadSizes(from url: URL) -> [String: Int64] {
        guard let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: Int64].self, from: data) else { return [:] }
        return table
    }

    /// 写失败（磁盘满、缓存目录被系统清了又建不出来）静默跳过，下次扫描会再试
    nonisolated static func saveSizes(_ table: [String: Int64], to url: URL) {
        guard let data = try? JSONEncoder().encode(table) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: 还原曲目

    /// 按歌单顺序把路径还原成曲目，`lookup` 找不到的跳过（文件被删了或还没扫到）
    func resolvedTracks(of id: Playlist.ID, in lookup: (String) -> Track?) -> [Track] {
        guard let list = playlists.first(where: { $0.id == id }) else { return [] }
        return list.items.compactMap(lookup)
    }

    /// 按加入顺序把最爱的路径还原成曲目，找不到的跳过
    func resolvedFavorites(in lookup: (String) -> Track?) -> [Track] {
        favorites.compactMap(lookup)
    }

    // MARK: 内部：读写

    /// 一次读到的两个文件。`newer` 表示任一文件的版本比本 App 新
    private struct Disk {
        let dir: URL
        var lists: PlaylistsFile
        var favorites: FavoritesFile
        var newer: Bool
    }

    private struct FileKey: Hashable {
        let name: String
        let size: Int64
    }

    /// 只看版本号的探针：更新的格式即使字段对不上，也能先判断出「版本更新」
    private struct VersionProbe: Decodable {
        let version: Int
    }

    private func readDisk() throws(PlaylistError) -> Disk {
        guard let dir = stateDir else { throw .notAttached }
        let lists = try Self.readFile(PlaylistsFile.self, at: dir.appending(path: "playlists.json"))
        let favorites = try Self.readFile(FavoritesFile.self, at: dir.appending(path: "favorites.json"))
        return Disk(dir: dir, lists: lists.value, favorites: favorites.value,
                    newer: lists.newer || favorites.newer)
    }

    /// 所有写操作的统一入口：先处理冲突，再读最新版本并同步到内存。
    /// 文件读不到、解不开、或版本比本 App 新，都在这里拦住，内存只按磁盘刷新、不做修改
    private func readForWrite() throws(PlaylistError) -> Disk {
        guard let dir = stateDir else { throw .notAttached }
        StateFile.resolveConflicts(at: dir.appending(path: "playlists.json"))
        StateFile.resolveConflicts(at: dir.appending(path: "favorites.json"))
        let disk = try readDisk()
        adopt(disk)
        if disk.newer { throw .readOnly }
        return disk
    }

    /// 把磁盘内容同步到内存。只读状态也在这里更新
    private func adopt(_ disk: Disk) {
        playlists = disk.lists.playlists
        favorites = disk.favorites.items
        isReadOnly = disk.newer
    }

    /// 改单个歌单的统一入口：找到歌单、改完、刷新 `updatedAt`、写盘。所有改歌单内容的操作都走这里，免得漏刷修改时间
    private func mutate(_ id: Playlist.ID, _ change: (inout Playlist) -> Void) throws(PlaylistError) {
        var disk = try readForWrite()
        guard let index = disk.lists.playlists.firstIndex(where: { $0.id == id }) else { throw .notFound }
        change(&disk.lists.playlists[index])
        disk.lists.playlists[index].updatedAt = Date()
        try commitLists(disk)
    }

    private func commitLists(_ disk: Disk) throws(PlaylistError) {
        try Self.writeFile(disk.lists, to: disk.dir.appending(path: "playlists.json"))
        adopt(disk)
    }

    private func commitFavorites(_ disk: Disk) throws(PlaylistError) {
        try Self.writeFile(disk.favorites, to: disk.dir.appending(path: "favorites.json"))
        adopt(disk)
    }

    /// 读一个状态文件。返回值里的 `newer` 为 true 表示版本比本 App 新。
    /// 版本更新但解不开时返回空内容 + `newer`，让调用方只读，而不是把它当空文件覆盖掉
    /// 不是 private：歌词偏移存储（`LyricOffsetStore`）读写 `.kapi/` 里的状态文件也走这一套，不再抄一份
    static func readFile<T: VersionedStateFile>(_ type: T.Type, at url: URL) throws(PlaylistError) -> (value: T, newer: Bool) {
        switch StateFile.read(url) {
        case .missing:
            return (T(), false)
        case .unavailable:
            throw .stillSyncing
        case .loaded(let data):
            let decoder = PlaylistCoding.makeDecoder()
            let version = (try? decoder.decode(VersionProbe.self, from: data))?.version
            let newer = (version ?? 0) > T.currentVersion
            do {
                return (try decoder.decode(T.self, from: data), newer)
            } catch {
                if newer { return (T(), true) }
                throw .unreadable
            }
        }
    }

    static func writeFile<T: VersionedStateFile>(_ value: T, to url: URL) throws(PlaylistError) {
        let data: Data
        do {
            data = try PlaylistCoding.makeEncoder().encode(value)
        } catch {
            throw .writeFailed
        }
        try writeData(data, to: url)
    }

    private static func writeData(_ data: Data, to url: URL) throws(PlaylistError) {
        do {
            try StateFile.write(data, to: url)
        } catch {
            throw .writeFailed
        }
    }

    /// 任意格式的图片转成最长边不超过 1024 的 JPEG。封面只要够看，不存原图，省 iCloud 空间
    static func makeCoverJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // 按 EXIF 方向转正，否则手机竖拍的封面会躺着存
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
