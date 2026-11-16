import XCTest
@testable import Kapi

/// 歌词时间微调：平移、落盘往返、只读、范围、路径认领。每个用例在临时目录里模拟一个 `Documents/`
@MainActor
final class LyricOffsetStoreTests: XCTestCase {
    nonisolated(unsafe) private var docs: URL!

    override func setUpWithError() throws {
        docs = FileManager.default.temporaryDirectory
            .appending(path: "KapiLyricOffsetTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: docs)
    }

    private var file: URL { docs.appending(path: ".kapi/lyric-offsets.json") }

    private func attachedStore() -> LyricOffsetStore {
        let store = LyricOffsetStore()
        store.attach(documentsURL: docs)
        return store
    }

    private func track(_ path: String, size: Int64 = 100) -> Track {
        Track(path: path, url: docs.appending(path: path), title: path, artist: nil,
              duration: 0, fileSize: size, format: "MP3", hasVideo: false, videoAspect: nil,
              createdAt: .distantPast, isDownloaded: true)
    }

    // MARK: 平移

    func testShiftedPositiveMakesLyricsEarlier() {
        let lines = [LyricLine(time: 10, text: "a"), LyricLine(time: 20, text: "b")]
        XCTAssertEqual(Lyrics.shifted(lines, by: 0.5).map(\.time), [9.5, 19.5])
    }

    func testShiftedNegativeMakesLyricsLater() {
        let lines = [LyricLine(time: 10, text: "a")]
        XCTAssertEqual(Lyrics.shifted(lines, by: -2).map(\.time), [12])
    }

    func testShiftedClampsAtZero() {
        let lines = [LyricLine(time: 1, text: "a"), LyricLine(time: 5, text: "b")]
        XCTAssertEqual(Lyrics.shifted(lines, by: 3).map(\.time), [0, 2])
    }

    func testShiftedZeroIsIdentity() {
        let lines = [LyricLine(time: 1, text: "a")]
        XCTAssertEqual(Lyrics.shifted(lines, by: 0), lines)
    }

    // MARK: 落盘

    func testSetOffsetPersistsAcrossStores() throws {
        try attachedStore().setOffset(500, for: track("a.mp3"))
        XCTAssertEqual(attachedStore().offsetMs(for: "a.mp3"), 500)
    }

    func testUnknownTrackHasZeroOffset() {
        XCTAssertEqual(attachedStore().offsetMs(for: "none.mp3"), 0)
    }

    func testSettingZeroRemovesEntry() throws {
        let store = attachedStore()
        try store.setOffset(500, for: track("a.mp3"))
        try store.setOffset(0, for: track("a.mp3"))
        XCTAssertNil(store.offsets["a.mp3"])
        XCTAssertEqual(attachedStore().offsetMs(for: "a.mp3"), 0)
    }

    func testOffsetIsClampedToLimit() throws {
        let store = attachedStore()
        try store.setOffset(999_999, for: track("a.mp3"))
        XCTAssertEqual(store.offsetMs(for: "a.mp3"), LyricOffsetStore.limitMs)
        try store.setOffset(-999_999, for: track("a.mp3"))
        XCTAssertEqual(store.offsetMs(for: "a.mp3"), -LyricOffsetStore.limitMs)
    }

    func testSetBeforeAttachThrowsNotAttached() {
        XCTAssertThrowsError(try LyricOffsetStore().setOffset(100, for: track("a.mp3"))) {
            XCTAssertEqual($0 as? PlaylistError, .notAttached)
        }
    }

    /// 写之前重读磁盘：另一台设备加的记录不能被本机的旧内存冲掉
    func testWriteKeepsEntriesAddedElsewhere() throws {
        let mine = attachedStore()
        try attachedStore().setOffset(300, for: track("other.mp3"))
        try mine.setOffset(500, for: track("a.mp3"))
        XCTAssertEqual(mine.offsetMs(for: "other.mp3"), 300)
        XCTAssertEqual(mine.offsetMs(for: "a.mp3"), 500)
    }

    func testNewerVersionIsReadOnlyAndUntouched() throws {
        let original = #"{"version": 99, "entries": [], "future": true}"#
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: file, atomically: true, encoding: .utf8)

        let store = attachedStore()
        XCTAssertTrue(store.isReadOnly)
        XCTAssertThrowsError(try store.setOffset(100, for: track("a.mp3"))) {
            XCTAssertEqual($0 as? PlaylistError, .readOnly)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    }

    func testCorruptFileIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try attachedStore().setOffset(100, for: track("a.mp3"))) {
            XCTAssertEqual($0 as? PlaylistError, .unreadable)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json")
    }

    // MARK: 认领

    func testRelocatedClaimsUniqueNameAndSize() {
        let entries = [LyricOffsetEntry(path: "old/a.mp3", size: 100, offsetMs: 500)]
        let moved = LyricOffsetStore.relocated(entries, live: [track("new/a.mp3", size: 100)])
        XCTAssertEqual(moved.map(\.path), ["new/a.mp3"])
        XCTAssertEqual(moved.first?.offsetMs, 500)
    }

    func testRelocatedSkipsAmbiguousCandidates() {
        let entries = [LyricOffsetEntry(path: "old/a.mp3", size: 100, offsetMs: 500)]
        let live = [track("x/a.mp3", size: 100), track("y/a.mp3", size: 100)]
        XCTAssertEqual(LyricOffsetStore.relocated(entries, live: live), entries)
    }

    func testRelocatedLeavesLiveAndUnmatchedEntriesAlone() {
        let entries = [
            LyricOffsetEntry(path: "a.mp3", size: 100, offsetMs: 500),
            LyricOffsetEntry(path: "gone.mp3", size: 7, offsetMs: -200),
        ]
        XCTAssertEqual(LyricOffsetStore.relocated(entries, live: [track("a.mp3", size: 100)]), entries)
    }

    func testRelocatedDoesNotOverwriteExistingEntryAtTarget() {
        let entries = [
            LyricOffsetEntry(path: "old/a.mp3", size: 100, offsetMs: 500),
            LyricOffsetEntry(path: "new/a.mp3", size: 100, offsetMs: -300),
        ]
        XCTAssertEqual(LyricOffsetStore.relocated(entries, live: [track("new/a.mp3", size: 100)]), entries)
    }

    func testRelocatedSkipsTwoOldPathsClaimingSameTarget() {
        let entries = [
            LyricOffsetEntry(path: "p/a.mp3", size: 100, offsetMs: 500),
            LyricOffsetEntry(path: "q/a.mp3", size: 100, offsetMs: 800),
        ]
        XCTAssertEqual(LyricOffsetStore.relocated(entries, live: [track("new/a.mp3", size: 100)]), entries)
    }

    func testRelocatePersistsClaim() throws {
        let store = attachedStore()
        try store.setOffset(500, for: track("old/a.mp3"))
        store.relocate(using: [track("new/a.mp3")])
        XCTAssertEqual(attachedStore().offsetMs(for: "new/a.mp3"), 500)
        XCTAssertEqual(attachedStore().offsetMs(for: "old/a.mp3"), 0)
    }
}
