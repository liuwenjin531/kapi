import XCTest
@testable import Kapi

/// 认领表落盘、歌单顺序调整、歌单页排序、播放队列认领这几块不依赖界面的逻辑
@MainActor
final class PlaylistViewsLogicTests: XCTestCase {
    nonisolated(unsafe) private var docs: URL!

    override func setUpWithError() throws {
        docs = FileManager.default.temporaryDirectory
            .appending(path: "KapiPlaylistViewsLogic-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: docs)
    }

    private var sizesFile: URL { docs.appending(path: "relocate-sizes.json") }

    private func makeStore() -> PlaylistStore {
        let store = PlaylistStore(sizesFile: sizesFile)
        store.attach(documentsURL: docs)
        return store
    }

    private func track(_ path: String, size: Int64) -> Track {
        Track(path: path, url: docs.appending(path: path), title: path, artist: nil,
              duration: 0, fileSize: size, format: "MP3", hasVideo: false, videoAspect: nil,
              createdAt: .distantPast, isDownloaded: true)
    }

    // MARK: 认领表落盘

    func testRelocateWritesSizesTable() throws {
        let store = makeStore()
        store.relocate(using: [track("a/x.mp3", size: 100), track("b.mp3", size: 7)])
        let table = PlaylistStore.loadSizes(from: sizesFile)
        XCTAssertEqual(table, ["a/x.mp3": 100, "b.mp3": 7])
    }

    /// 冷启动：上次运行记下了大小，重启后文件已被挪走，也能认领回来
    func testSizesSurviveRestartSoColdMovedFileIsClaimed() throws {
        let first = makeStore()
        let list = try first.create(name: "A")
        try first.add(["old/x.mp3"], to: list.id)
        first.relocate(using: [track("old/x.mp3", size: 100)])

        // 模拟 App 被杀、文件在 App 没开着时被挪走
        let second = makeStore()
        second.relocate(using: [track("new/x.mp3", size: 100)])
        XCTAssertEqual(second.playlists[0].items, ["new/x.mp3"])
    }

    func testMissingOrCorruptSizesFileIsEmptyTable() throws {
        XCTAssertEqual(PlaylistStore.loadSizes(from: sizesFile), [:])
        try Data("{ nope".utf8).write(to: sizesFile)
        XCTAssertEqual(PlaylistStore.loadSizes(from: sizesFile), [:])
        // 坏文件不影响 attach
        XCTAssertNoThrow(try makeStore().create(name: "ok"))
    }

    // MARK: 歌单顺序

    func testMovePlaylistsPersistsOrder() throws {
        let store = makeStore()
        for name in ["A", "B", "C"] { try store.create(name: name) }
        try store.movePlaylists(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.playlists.map(\.name), ["C", "A", "B"])
        XCTAssertEqual(makeStore().playlists.map(\.name), ["C", "A", "B"])
        try store.movePlaylists(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(store.playlists.map(\.name), ["A", "B", "C"])
    }

    func testMovePlaylistsOutOfRangeIsNoop() throws {
        let store = makeStore()
        for name in ["A", "B"] { try store.create(name: name) }
        try store.movePlaylists(from: IndexSet(integer: 5), to: 0)
        try store.movePlaylists(from: IndexSet(integer: 0), to: 9)
        XCTAssertEqual(store.playlists.map(\.name), ["A", "B"])
    }

    // MARK: 歌单页排序

    private func list(_ name: String, created: Double, played: Double?) -> Playlist {
        Playlist(id: UUID(), name: name, cover: nil, items: [],
                 createdAt: Date(timeIntervalSince1970: created), updatedAt: .distantPast,
                 lastPlayedAt: played.map { Date(timeIntervalSince1970: $0) })
    }

    func testSortingKeys() {
        let a = list("乙", created: 1, played: nil)
        let b = list("甲", created: 3, played: 10)
        let c = list("丙", created: 2, played: 20)
        let all = [a, b, c]
        XCTAssertEqual(PlaylistSorting.sorted(all, by: .custom).map(\.name), ["乙", "甲", "丙"])
        XCTAssertEqual(PlaylistSorting.sorted(all, by: .name).map(\.name), ["丙", "甲", "乙"])
        XCTAssertEqual(PlaylistSorting.sorted(all, by: .dateAdded).map(\.name), ["甲", "丙", "乙"])
        // 上次播放：新的在前，从没播过的排最后
        XCTAssertEqual(PlaylistSorting.sorted(all, by: .lastPlayed).map(\.name), ["丙", "甲", "乙"])
    }

    // MARK: 播放队列认领

    func testQueueRelocationClaimsUniqueMatchOnly() {
        let moved = track("old/a.mp3", size: 10)
        let ambiguous = track("old/b.mp3", size: 20)
        let stays = track("c.mp3", size: 30)
        let live = [track("new/a.mp3", size: 10),
                    track("x/b.mp3", size: 20), track("y/b.mp3", size: 20),
                    stays]
        let result = QueueRelocation.moves(queue: [moved, ambiguous, stays], live: live)
        XCTAssertEqual(result.keys.sorted(), ["old/a.mp3"])
        XCTAssertEqual(result["old/a.mp3"]?.path, "new/a.mp3")
    }

    func testQueueRelocationIgnoresSameNameDifferentSize() {
        let result = QueueRelocation.moves(queue: [track("old/a.mp3", size: 10)],
                                           live: [track("new/a.mp3", size: 11)])
        XCTAssertTrue(result.isEmpty)
    }

    func testQueueRelocationTwoOldToSameNewIsAmbiguous() {
        let result = QueueRelocation.moves(
            queue: [track("p/a.mp3", size: 10), track("q/a.mp3", size: 10)],
            live: [track("new/a.mp3", size: 10)])
        XCTAssertTrue(result.isEmpty)
    }
}
