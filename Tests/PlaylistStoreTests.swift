import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Kapi

/// 歌单与最爱的落盘逻辑：往返、只读、占位拦截、写前重读、封面、认领、还原。
/// 每个用例在临时目录里模拟一个 `Documents/`
@MainActor
final class PlaylistStoreTests: XCTestCase {
    // XCTest 的 setUp/tearDown 不在主线程隔离里运行，这里只在它们里面赋值一次，所以标 unsafe 是安全的
    nonisolated(unsafe) private var docs: URL!

    override func setUpWithError() throws {
        docs = FileManager.default.temporaryDirectory
            .appending(path: "KapiPlaylistStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: docs)
    }

    private var stateDir: URL { docs.appending(path: ".kapi", directoryHint: .isDirectory) }

    private func attachedStore() -> PlaylistStore {
        // 认领表写到临时目录，不碰真实的 Caches，用例之间也互不影响
        let store = PlaylistStore(sizesFile: docs.appending(path: "relocate-sizes.json"))
        store.attach(documentsURL: docs)
        return store
    }

    private func track(_ path: String, size: Int64) -> Track {
        Track(path: path, url: docs.appending(path: path), title: path, artist: nil,
              duration: 0, fileSize: size, format: "MP3", hasVideo: false, videoAspect: nil,
              createdAt: .distantPast, isDownloaded: true)
    }

    /// 直接往磁盘写一份歌单文件，模拟「另一台设备」改过的内容
    private func writePlaylists(_ file: PlaylistsFile) throws {
        let data = try PlaylistCoding.makeEncoder().encode(file)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try data.write(to: stateDir.appending(path: "playlists.json"))
    }

    private func writeFavorites(_ file: FavoritesFile) throws {
        let data = try PlaylistCoding.makeEncoder().encode(file)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try data.write(to: stateDir.appending(path: "favorites.json"))
    }

    private func playlist(_ name: String, items: [String] = [], id: UUID = UUID()) -> Playlist {
        // 固定在过去的时间：改动后的 updatedAt 必须严格晚于它，断言才有意义
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return Playlist(id: id, name: name, cover: nil, items: items,
                        createdAt: date, updatedAt: date, lastPlayedAt: nil)
    }

    // MARK: 往返

    func testCreateAddPersistsAcrossStores() throws {
        let store = attachedStore()
        let list = try store.create(name: "通勤路上")
        try store.add(["华语/夜航船.flac", "旅行路上/国道 318.mp3", "华语/夜航船.flac"], to: list.id)
        try store.toggleFavorite("华语/夜航船.flac")

        // 新的实例重新挂载，应当读到同样的内容
        let reopened = attachedStore()
        XCTAssertEqual(reopened.playlists.map(\.name), ["通勤路上"])
        XCTAssertEqual(reopened.playlists.first?.items, ["华语/夜航船.flac", "旅行路上/国道 318.mp3"])
        XCTAssertEqual(reopened.favorites, ["华语/夜航船.flac"])
        XCTAssertTrue(reopened.isFavorite("华语/夜航船.flac"))
    }

    func testCreateSetsCreatedAndUpdatedToSameTime() throws {
        let store = attachedStore()
        let list = try store.create(name: "A")
        XCTAssertEqual(list.createdAt, list.updatedAt)
    }

    func testMutationRefreshesUpdatedAt() throws {
        let list = playlist("旧名", id: UUID())
        try writePlaylists(PlaylistsFile(playlists: [list]))
        let store = attachedStore()
        try store.rename(list.id, to: "新名")
        XCTAssertGreaterThan(store.playlists[0].updatedAt, list.updatedAt)
        XCTAssertEqual(store.playlists[0].name, "新名")
    }

    func testMarkPlayedDoesNotTouchUpdatedAt() throws {
        let list = playlist("A")
        try writePlaylists(PlaylistsFile(playlists: [list]))
        let store = attachedStore()
        store.markPlayed(list.id)
        XCTAssertNotNil(store.playlists[0].lastPlayedAt)
        XCTAssertEqual(store.playlists[0].updatedAt, list.updatedAt)
    }

    func testNotFoundThrows() throws {
        let store = attachedStore()
        XCTAssertThrowsError(try store.rename(UUID(), to: "x")) { error in
            XCTAssertEqual(error as? PlaylistError, .notFound)
        }
    }

    func testRemoveOutOfRangeIsIgnored() throws {
        let store = attachedStore()
        let list = try store.create(name: "A")
        try store.add(["a.mp3", "b.mp3"], to: list.id)
        try store.remove(at: IndexSet([0, 9]), from: list.id)
        XCTAssertEqual(attachedStore().playlists[0].items, ["b.mp3"])
    }

    /// 与 SwiftUI `onMove` 同样的语义：目标下标以移动前的数组为准
    func testMoveFollowsOnMoveSemantics() throws {
        let store = attachedStore()
        let list = try store.create(name: "A")
        try store.add(["a", "b", "c", "d"], to: list.id)
        try store.move(from: IndexSet([0]), to: 3, in: list.id)
        XCTAssertEqual(attachedStore().playlists[0].items, ["b", "c", "a", "d"])
        try store.move(from: IndexSet([3]), to: 0, in: list.id)
        XCTAssertEqual(attachedStore().playlists[0].items, ["d", "b", "c", "a"])
        try store.move(from: IndexSet([1, 2]), to: 4, in: list.id)
        XCTAssertEqual(attachedStore().playlists[0].items, ["d", "a", "b", "c"])
    }

    // MARK: 只读与拦截

    func testNewerVersionIsReadOnlyAndFileUntouched() throws {
        // 版本 2 的文件：字段结构可能不同，这里放一份能解开的，只验证只读
        let json = #"{"version":2,"playlists":[{"id":"4E1C2B9A-0000-0000-0000-000000000000","name":"新版","cover":null,"items":[],"createdAt":"2026-11-12T22:00:00Z","updatedAt":"2026-11-12T22:00:00Z","lastPlayedAt":null}]}"#
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let url = stateDir.appending(path: "playlists.json")
        try Data(json.utf8).write(to: url)

        let store = attachedStore()
        XCTAssertTrue(store.isReadOnly)
        XCTAssertEqual(store.playlists.map(\.name), ["新版"])
        XCTAssertThrowsError(try store.create(name: "x")) { XCTAssertEqual($0 as? PlaylistError, .readOnly) }
        XCTAssertThrowsError(try store.toggleFavorite("a.mp3")) { XCTAssertEqual($0 as? PlaylistError, .readOnly) }
        XCTAssertEqual(try Data(contentsOf: url), Data(json.utf8))
    }

    func testNewerUndecodableVersionIsReadOnlyWithEmptyContent() throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let url = stateDir.appending(path: "favorites.json")
        let json = #"{"version":3,"someFutureShape":{"a":1}}"#
        try Data(json.utf8).write(to: url)

        let store = attachedStore()
        XCTAssertTrue(store.isReadOnly)
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertThrowsError(try store.toggleFavorite("a.mp3"))
        XCTAssertEqual(try Data(contentsOf: url), Data(json.utf8))
    }

    /// 占位存在、文件暂时读不到：写操作抛 stillSyncing，磁盘上不新建任何文件
    func testPlaceholderBlocksWriteWithStillSyncing() throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Data().write(to: stateDir.appending(path: ".playlists.json.icloud"))

        let store = attachedStore()
        XCTAssertThrowsError(try store.create(name: "x")) { XCTAssertEqual($0 as? PlaylistError, .stillSyncing) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir.appending(path: "playlists.json").path))
    }

    /// 文件坏了（解不开）：不写，避免把它整份覆盖掉
    func testCorruptFileBlocksWrite() throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let url = stateDir.appending(path: "playlists.json")
        try Data("{ not json".utf8).write(to: url)

        let store = attachedStore()
        XCTAssertThrowsError(try store.create(name: "x")) { XCTAssertEqual($0 as? PlaylistError, .unreadable) }
        XCTAssertEqual(try Data(contentsOf: url), Data("{ not json".utf8))
    }

    func testNotAttachedThrows() {
        let store = PlaylistStore()
        XCTAssertThrowsError(try store.create(name: "x")) { XCTAssertEqual($0 as? PlaylistError, .notAttached) }
    }

    // MARK: 写前重读

    /// 本机内存里没有另一台设备加的歌单，写入时要在最新文件上改，不能把它冲掉
    func testWriteReadsLatestFileFirst() throws {
        let store = attachedStore()
        _ = try store.create(name: "本机")

        let other = playlist("另一台")
        try writePlaylists(PlaylistsFile(playlists: store.playlists + [other]))

        // 本机内存还是旧的，这次写入应当保留另一台设备的歌单
        _ = try store.create(name: "本机再建")
        let names = attachedStore().playlists.map(\.name)
        XCTAssertEqual(names, ["本机", "另一台", "本机再建"])
    }

    func testReloadPicksUpExternalChange() throws {
        let store = attachedStore()
        try writePlaylists(PlaylistsFile(playlists: [playlist("外部")]))
        store.reload()
        XCTAssertEqual(store.playlists.map(\.name), ["外部"])
    }

    // MARK: 封面

    func testSetCoverWritesJPEGAndClearRemovesIt() throws {
        let store = attachedStore()
        let list = try store.create(name: "A")
        try store.setCover(list.id, imageData: makePNG(width: 2000, height: 1000))

        let coverFile = stateDir.appending(path: "covers/\(list.id.uuidString).jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverFile.path))
        XCTAssertEqual(attachedStore().playlists[0].cover, "covers/\(list.id.uuidString).jpg")

        // 最长边应当被压到 1024 以内
        let source = CGImageSourceCreateWithURL(coverFile as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        XCTAssertLessThanOrEqual(max(width, height), 1024)
        XCTAssertEqual(width, 1024)

        try store.setCover(list.id, imageData: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coverFile.path))
        XCTAssertNil(attachedStore().playlists[0].cover)
    }

    func testSetCoverRejectsGarbageImage() throws {
        let store = attachedStore()
        let list = try store.create(name: "A")
        XCTAssertThrowsError(try store.setCover(list.id, imageData: Data("不是图片".utf8))) {
            XCTAssertEqual($0 as? PlaylistError, .unreadable)
        }
        XCTAssertNil(attachedStore().playlists[0].cover)
    }

    // MARK: 认领

    func testRelocateClaimsUniqueMatchByNameAndSize() throws {
        let list = playlist("A", items: ["华语/夜航船.flac", "b/song.mp3"])
        try writePlaylists(PlaylistsFile(playlists: [list]))
        try writeFavorites(FavoritesFile(items: ["华语/夜航船.flac"]))
        let store = attachedStore()

        // 第一次扫描：记下两首的大小
        store.relocate(using: [track("华语/夜航船.flac", size: 100), track("b/song.mp3", size: 50)])
        // 第二次扫描：夜航船被挪到新文件夹，song.mp3 不见了
        store.relocate(using: [track("新/夜航船.flac", size: 100)])

        let reopened = attachedStore()
        XCTAssertEqual(reopened.playlists[0].items, ["新/夜航船.flac", "b/song.mp3"], "唯一匹配的认领，找不到的保留")
        XCTAssertEqual(reopened.favorites, ["新/夜航船.flac"])
        XCTAssertEqual(reopened.playlists[0].updatedAt, list.updatedAt, "认领不算用户修改")
    }

    func testRelocateDoesNotClaimWhenSameNameAndSizeAreAmbiguous() throws {
        let list = playlist("A", items: ["c/dup.mp3"])
        try writePlaylists(PlaylistsFile(playlists: [list]))
        let store = attachedStore()

        store.relocate(using: [track("c/dup.mp3", size: 30)])
        store.relocate(using: [track("x/dup.mp3", size: 30), track("y/dup.mp3", size: 30)])

        XCTAssertEqual(attachedStore().playlists[0].items, ["c/dup.mp3"])
    }

    func testRelocateDoesNotClaimWhenSizeDiffers() throws {
        let list = playlist("A", items: ["c/song.mp3"])
        try writePlaylists(PlaylistsFile(playlists: [list]))
        let store = attachedStore()

        store.relocate(using: [track("c/song.mp3", size: 30)])
        store.relocate(using: [track("x/song.mp3", size: 31)])

        XCTAssertEqual(attachedStore().playlists[0].items, ["c/song.mp3"])
    }

    func testRelocateKeepsPathsWithUnknownSize() throws {
        // 从没扫到过的路径没有大小，认领不了，原样保留
        let list = playlist("A", items: ["never/seen.mp3"])
        try writePlaylists(PlaylistsFile(playlists: [list]))
        let store = attachedStore()
        store.relocate(using: [track("elsewhere/seen.mp3", size: 10)])
        XCTAssertEqual(attachedStore().playlists[0].items, ["never/seen.mp3"])
    }

    func testRelocateTwoOldPathsToSameTargetLeavesBoth() throws {
        // 两条旧路径都认领到同一个新文件，判断有歧义，两条都不动
        let list = playlist("A", items: ["p/a.mp3", "q/a.mp3"])
        try writePlaylists(PlaylistsFile(playlists: [list]))
        let store = attachedStore()
        store.relocate(using: [track("p/a.mp3", size: 7), track("q/a.mp3", size: 7)])
        store.relocate(using: [track("z/a.mp3", size: 7)])
        XCTAssertEqual(attachedStore().playlists[0].items, ["p/a.mp3", "q/a.mp3"])
    }

    // MARK: 还原

    func testResolvedTracksSkipsMissing() throws {
        let list = playlist("A", items: ["a.mp3", "gone.mp3", "b.mp3"])
        try writePlaylists(PlaylistsFile(playlists: [list]))
        let store = attachedStore()
        let library = [track("a.mp3", size: 1), track("b.mp3", size: 2)]
        let lookup: (String) -> Track? = { path in library.first { $0.path == path } }

        XCTAssertEqual(store.resolvedTracks(of: list.id, in: lookup).map(\.path), ["a.mp3", "b.mp3"])
        XCTAssertTrue(store.resolvedTracks(of: UUID(), in: lookup).isEmpty)
    }

    func testResolvedFavoritesKeepsOrder() throws {
        try writeFavorites(FavoritesFile(items: ["b.mp3", "gone.mp3", "a.mp3"]))
        let store = attachedStore()
        let library = [track("a.mp3", size: 1), track("b.mp3", size: 2)]
        let lookup: (String) -> Track? = { path in library.first { $0.path == path } }
        XCTAssertEqual(store.resolvedFavorites(in: lookup).map(\.path), ["b.mp3", "a.mp3"])
    }

    // MARK: 工具

    /// 生成一张纯色 PNG，用来测封面压缩
    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
