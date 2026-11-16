import XCTest
@testable import Kapi

/// 整理文件：重命名、移动、拷贝、删文件夹（在临时目录里真的建文件），
/// 以及路径映射、歌单 / 最爱 / 歌词微调跟着改路径
@MainActor
final class LibraryOrganizeTests: XCTestCase {
    nonisolated(unsafe) private var docs: URL!

    override func setUpWithError() throws {
        docs = FileManager.default.temporaryDirectory
            .appending(path: "KapiOrganizeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: docs)
    }

    private var files: LibraryFiles { LibraryFiles(documentsURL: docs) }

    // MARK: 工具

    @discardableResult
    private func make(_ path: String, _ content: String = "x") throws -> URL {
        let url = docs.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeDir(_ path: String) throws {
        try FileManager.default.createDirectory(at: docs.appending(path: path), withIntermediateDirectories: true)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: docs.appending(path: path).path(percentEncoded: false))
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: docs.appending(path: path), encoding: .utf8)
    }

    private func track(_ path: String, size: Int64 = 1) -> Track {
        Track(path: path, url: docs.appending(path: path), title: path, artist: nil,
              duration: 0, fileSize: size, format: "MP3", hasVideo: false, videoAspect: nil,
              createdAt: .distantPast, isDownloaded: true)
    }

    // MARK: 名称校验

    func testCleanName() throws {
        XCTAssertEqual(try LibraryFiles.cleanName("  夜曲 "), "夜曲")
        for bad in ["", "   ", "a/b", "a:b", ".hidden"] {
            XCTAssertThrowsError(try LibraryFiles.cleanName(bad)) {
                XCTAssertEqual($0 as? LibraryFiles.FileError, .invalidName)
            }
        }
    }

    // MARK: 重命名歌

    func testRenameSongKeepsExtensionAndMovesLyric() async throws {
        try make("华语/夜曲.mp3", "song")
        try make("华语/夜曲.lrc", "lyric")
        let result = try await files.renameSong(track("华语/夜曲.mp3"), to: "新名字")
        XCTAssertEqual(result.changes, [PathChange(old: "华语/夜曲.mp3", new: "华语/新名字.mp3", isFolder: false)])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(read("华语/新名字.mp3"), "song")
        XCTAssertEqual(read("华语/新名字.lrc"), "lyric")
        XCTAssertFalse(exists("华语/夜曲.mp3"))
        XCTAssertFalse(exists("华语/夜曲.lrc"))
    }

    func testRenameSongInRootFolder() async throws {
        try make("a.flac")
        let result = try await files.renameSong(track("a.flac"), to: "b")
        XCTAssertEqual(result.changes.first?.new, "b.flac")
        XCTAssertTrue(exists("b.flac"))
    }

    func testRenameSongSameNameIsNoOp() async throws {
        try make("a.mp3")
        let result = try await files.renameSong(track("a.mp3"), to: "a")
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(exists("a.mp3"))
    }

    func testRenameSongToTakenNameFails() async throws {
        try make("a.mp3", "A")
        try make("b.mp3", "B")
        do {
            _ = try await files.renameSong(track("a.mp3"), to: "b")
            XCTFail("应当抛出 nameTaken")
        } catch {
            XCTAssertEqual(error as? LibraryFiles.FileError, .nameTaken)
        }
        XCTAssertEqual(read("a.mp3"), "A")
        XCTAssertEqual(read("b.mp3"), "B")
    }

    func testRenameSongFailsWhenTargetLyricTaken() async throws {
        try make("a.mp3")
        try make("a.lrc")
        try make("b.lrc", "orphan")   // 目标名的歌词已被占着，改名后歌和歌词会对错
        do {
            _ = try await files.renameSong(track("a.mp3"), to: "b")
            XCTFail("应当抛出 nameTaken")
        } catch {
            XCTAssertEqual(error as? LibraryFiles.FileError, .nameTaken)
        }
        XCTAssertTrue(exists("a.mp3"))
        XCTAssertEqual(read("b.lrc"), "orphan")
    }

    func testRenameSongInvalidName() async throws {
        try make("a.mp3")
        do {
            _ = try await files.renameSong(track("a.mp3"), to: "x/y")
            XCTFail("应当抛出 invalidName")
        } catch {
            XCTAssertEqual(error as? LibraryFiles.FileError, .invalidName)
        }
    }

    func testRenameSongRejectsUnsafePath() async throws {
        do {
            _ = try await files.renameSong(track("../a.mp3"), to: "b")
            XCTFail("应当抛出 invalidPath")
        } catch {
            XCTAssertEqual(error as? LibraryFiles.FileError, .invalidPath)
        }
    }

    // MARK: 重命名文件夹

    func testRenameFolder() async throws {
        try make("华语/a.mp3")
        try make("华语/子/b.mp3")
        let result = try await files.renameFolder("华语", to: "国语")
        XCTAssertEqual(result.changes, [PathChange(old: "华语", new: "国语", isFolder: true)])
        XCTAssertTrue(exists("国语/a.mp3"))
        XCTAssertTrue(exists("国语/子/b.mp3"))
        XCTAssertFalse(exists("华语"))
    }

    func testRenameNestedFolder() async throws {
        try make("A/B/x.mp3")
        let result = try await files.renameFolder("A/B", to: "C")
        XCTAssertEqual(result.changes.first?.new, "A/C")
        XCTAssertTrue(exists("A/C/x.mp3"))
    }

    func testRenameFolderToTakenNameFailsAndRootRejected() async throws {
        try makeDir("A")
        try makeDir("B")
        do {
            _ = try await files.renameFolder("A", to: "B")
            XCTFail("应当抛出 nameTaken")
        } catch {
            XCTAssertEqual(error as? LibraryFiles.FileError, .nameTaken)
        }
        do {
            _ = try await files.renameFolder("", to: "X")
            XCTFail("根目录不能改名")
        } catch {
            XCTAssertEqual(error as? LibraryFiles.FileError, .invalidPath)
        }
    }

    // MARK: 移动

    func testMoveSongTakesLyricAlong() async throws {
        try make("a/s.mp3", "song")
        try make("a/s.lrc", "lyric")
        try makeDir("b")
        let result = try await files.move(songs: [track("a/s.mp3")], folders: [], to: "b")
        XCTAssertEqual(result.changes, [PathChange(old: "a/s.mp3", new: "b/s.mp3", isFolder: false)])
        XCTAssertEqual(read("b/s.mp3"), "song")
        XCTAssertEqual(read("b/s.lrc"), "lyric")
        XCTAssertFalse(exists("a/s.mp3"))
        XCTAssertFalse(exists("a/s.lrc"))
    }

    func testMoveSongToRoot() async throws {
        try make("a/s.mp3")
        let result = try await files.move(songs: [track("a/s.mp3")], folders: [], to: "")
        XCTAssertEqual(result.changes.first?.new, "s.mp3")
        XCTAssertTrue(exists("s.mp3"))
    }

    func testMoveSongNameCollisionAddsSuffixAndKeepsLyricPaired() async throws {
        try make("a/s.mp3", "new")
        try make("a/s.lrc", "newlyric")
        try make("b/s.mp3", "old")
        try make("b/s.lrc", "oldlyric")
        let result = try await files.move(songs: [track("a/s.mp3")], folders: [], to: "b")
        XCTAssertEqual(result.changes.first?.new, "b/s 2.mp3")
        XCTAssertEqual(read("b/s.mp3"), "old")
        XCTAssertEqual(read("b/s 2.mp3"), "new")
        XCTAssertEqual(read("b/s.lrc"), "oldlyric")
        XCTAssertEqual(read("b/s 2.lrc"), "newlyric")
    }

    func testMoveSongSkipsWhenOrphanLyricOccupiesSuffixedName() async throws {
        // 目标里有同名歌，且「s 2.lrc」被孤儿歌词占着：歌只能改叫「s 3.mp3」，歌词才对得上
        try make("a/s.mp3", "new")
        try make("a/s.lrc", "newlyric")
        try make("b/s.mp3", "old")
        try make("b/s 2.lrc", "orphan")
        let result = try await files.move(songs: [track("a/s.mp3")], folders: [], to: "b")
        XCTAssertEqual(result.changes.first?.new, "b/s 3.mp3")
        XCTAssertEqual(read("b/s 3.lrc"), "newlyric")
        XCTAssertEqual(read("b/s 2.lrc"), "orphan")
    }

    func testMoveToSameFolderDoesNothing() async throws {
        try make("a/s.mp3")
        try makeDir("a/sub")
        let result = try await files.move(songs: [track("a/s.mp3")], folders: ["a/sub"], to: "a")
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(result.succeeded, 0)
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertTrue(exists("a/s.mp3"))
        XCTAssertTrue(exists("a/sub"))
    }

    func testMoveFolderIntoItselfOrDescendantRejected() async throws {
        try make("A/B/x.mp3")
        for destination in ["A", "A/B"] {
            do {
                _ = try await files.move(songs: [], folders: ["A"], to: destination)
                XCTFail("应当抛出 intoItself")
            } catch {
                XCTAssertEqual(error as? LibraryFiles.FileError, .intoItself)
            }
        }
        XCTAssertTrue(exists("A/B/x.mp3"))
        // 名字是前缀但不是子孙的不算
        try makeDir("A2")
        let ok = try await files.move(songs: [], folders: ["A"], to: "A2")
        XCTAssertEqual(ok.changes.first?.new, "A2/A")
        XCTAssertTrue(exists("A2/A/B/x.mp3"))
    }

    func testMoveFolderNameCollisionAddsSuffix() async throws {
        try make("a/Vol.1/x.mp3")
        try make("b/Vol.1/y.mp3")
        let result = try await files.move(songs: [], folders: ["a/Vol.1"], to: "b")
        // 文件夹名里的点不是扩展名：「Vol.1 2」而不是「Vol 2.1」
        XCTAssertEqual(result.changes.first?.new, "b/Vol.1 2")
        XCTAssertTrue(exists("b/Vol.1 2/x.mp3"))
        XCTAssertTrue(exists("b/Vol.1/y.mp3"))
    }

    func testMoveBatchMixed() async throws {
        try make("src/a.mp3")
        try make("src/b.mp3")
        try make("src/dir/c.mp3")
        try makeDir("dst")
        let result = try await files.move(songs: [track("src/a.mp3"), track("src/b.mp3")],
                                          folders: ["src/dir"], to: "dst")
        XCTAssertEqual(result.succeeded, 3)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(exists("dst/a.mp3") && exists("dst/b.mp3") && exists("dst/dir/c.mp3"))
    }

    func testMoveBatchReportsFailureForMissingSourceButContinues() async throws {
        try make("src/a.mp3")
        try makeDir("dst")
        let result = try await files.move(songs: [track("src/gone.mp3"), track("src/a.mp3")], folders: [], to: "dst")
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].hasPrefix("gone.mp3"))
        XCTAssertTrue(exists("dst/a.mp3"))
    }

    func testMoveToMissingDestinationFails() async throws {
        try make("a.mp3")
        do {
            _ = try await files.move(songs: [track("a.mp3")], folders: [], to: "nope")
            XCTFail("应当抛出 destinationMissing")
        } catch {
            XCTAssertEqual(error as? LibraryFiles.FileError, .destinationMissing)
        }
    }

    func testMoveRejectsUnsafeDestination() async throws {
        try make("a.mp3")
        do {
            _ = try await files.move(songs: [track("a.mp3")], folders: [], to: "../x")
            XCTFail("应当抛出 invalidPath")
        } catch {
            XCTAssertEqual(error as? LibraryFiles.FileError, .invalidPath)
        }
    }

    // MARK: 拷贝

    func testCopySongKeepsOriginalAndCopiesLyric() async throws {
        try make("a/s.mp3", "song")
        try make("a/s.lrc", "lyric")
        try makeDir("b")
        let result = try await files.copy(songs: [track("a/s.mp3")], folders: [], to: "b")
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertTrue(result.changes.isEmpty, "拷贝不改原路径")
        XCTAssertEqual(read("a/s.mp3"), "song")
        XCTAssertEqual(read("a/s.lrc"), "lyric")
        XCTAssertEqual(read("b/s.mp3"), "song")
        XCTAssertEqual(read("b/s.lrc"), "lyric")
    }

    func testCopyToSameFolderMakesNumberedDuplicate() async throws {
        try make("a/s.mp3", "song")
        try make("a/s.lrc", "lyric")
        let result = try await files.copy(songs: [track("a/s.mp3")], folders: [], to: "a")
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(read("a/s 2.mp3"), "song")
        XCTAssertEqual(read("a/s 2.lrc"), "lyric")
        XCTAssertEqual(read("a/s.mp3"), "song")
    }

    func testCopyFolderRecursively() async throws {
        try make("A/x.mp3", "x")
        try make("A/sub/y.mp3", "y")
        try makeDir("B")
        let result = try await files.copy(songs: [], folders: ["A"], to: "B")
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(read("B/A/x.mp3"), "x")
        XCTAssertEqual(read("B/A/sub/y.mp3"), "y")
        XCTAssertEqual(read("A/x.mp3"), "x")
    }

    func testCopyFolderIntoItselfRejected() async throws {
        try make("A/B/x.mp3")
        for destination in ["A", "A/B"] {
            do {
                _ = try await files.copy(songs: [], folders: ["A"], to: destination)
                XCTFail("应当抛出 intoItself")
            } catch {
                XCTAssertEqual(error as? LibraryFiles.FileError, .intoItself)
            }
        }
    }

    func testCopyBatchSameNamesGetDistinctSuffixes() async throws {
        // 同一批里两首同名歌（来自不同目录的场景由多选限制在同层，这里直接给同名路径验证 taken 集合）
        try make("a/s.mp3", "one")
        try makeDir("b")
        let result = try await files.copy(songs: [track("a/s.mp3"), track("a/s.mp3")], folders: [], to: "b")
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertTrue(exists("b/s.mp3"))
        XCTAssertTrue(exists("b/s 2.mp3"))
    }

    // MARK: 删除

    func testDeleteFolderRemovesContents() async throws {
        try make("A/x.mp3")
        try make("A/sub/y.mp3")
        try await files.deleteFolder("A")
        XCTAssertFalse(exists("A"))
    }

    func testDeleteFolderRejectsRootAndUnsafe() async throws {
        try make("keep.mp3")
        for bad in ["", "../x"] {
            do {
                try await files.deleteFolder(bad)
                XCTFail("应当拒绝 \(bad)")
            } catch {
                XCTAssertEqual(error as? LibraryFiles.FileError, .invalidPath)
            }
        }
        XCTAssertTrue(exists("keep.mp3"))
    }

    func testDeleteBatchSongsWithLyricAndFolders() async throws {
        try make("a.mp3")
        try make("a.lrc")
        try make("D/b.mp3")
        let result = await files.delete(songs: [track("a.mp3")], folders: ["D"])
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(exists("a.mp3"))
        XCTAssertFalse(exists("a.lrc"))
        XCTAssertFalse(exists("D"))
    }

    // MARK: 路径映射

    func testPathMappingFileAndFolderPrefix() {
        let changes = [PathChange(old: "华语", new: "国语", isFolder: true),
                       PathChange(old: "x/a.mp3", new: "y/b.mp3", isFolder: false)]
        XCTAssertEqual(PathMapping.mapped("华语/a.mp3", by: changes), "国语/a.mp3")
        XCTAssertEqual(PathMapping.mapped("华语/子/b.mp3", by: changes), "国语/子/b.mp3")
        XCTAssertEqual(PathMapping.mapped("x/a.mp3", by: changes), "y/b.mp3")
        XCTAssertNil(PathMapping.mapped("华语2/a.mp3", by: changes), "前缀要带 / 比较，不能误伤同前缀的别的文件夹")
        XCTAssertNil(PathMapping.mapped("x/a.mp3.bak", by: changes))
        XCTAssertNil(PathMapping.mapped("其他/a.mp3", by: changes))
    }

    func testPathMappingFolderMovedToRootAndFromRoot() {
        XCTAssertEqual(PathMapping.mapped("a/b/c.mp3", by: [PathChange(old: "a/b", new: "b", isFolder: true)]), "b/c.mp3")
        XCTAssertEqual(PathMapping.mapped("b/c.mp3", by: [PathChange(old: "b", new: "a/b", isFolder: true)]), "a/b/c.mp3")
    }

    func testIsInside() {
        XCTAssertTrue(LibraryFiles.isInside("A", of: "A"))
        XCTAssertTrue(LibraryFiles.isInside("A/B", of: "A"))
        XCTAssertFalse(LibraryFiles.isInside("A2", of: "A"))
        XCTAssertFalse(LibraryFiles.isInside("", of: "A"))
        XCTAssertFalse(LibraryFiles.isInside("A", of: ""), "根目录不会被移动")
    }

    // MARK: 歌单 / 最爱

    private func attachedPlaylists() -> PlaylistStore {
        let store = PlaylistStore(sizesFile: docs.appending(path: "relocate-sizes.json"))
        store.attach(documentsURL: docs)
        return store
    }

    func testPlaylistRemappedDedupesKeepingFirst() {
        let out = PlaylistStore.remapped(["a.mp3", "b.mp3", "c.mp3"],
                                         by: [PathChange(old: "a.mp3", new: "b.mp3", isFolder: false)])
        XCTAssertEqual(out, ["b.mp3", "c.mp3"])
    }

    func testPlaylistStoreApplyMovesRewritesPlaylistsAndFavoritesAndPersists() throws {
        let store = attachedPlaylists()
        let list = try store.create(name: "L")
        try store.add(["华语/a.mp3", "华语/子/b.mp3", "other.mp3"], to: list.id)
        try store.toggleFavorite("华语/a.mp3")
        let before = store.playlists[0].updatedAt

        try store.applyMoves([PathChange(old: "华语", new: "国语", isFolder: true)])

        XCTAssertEqual(store.playlists[0].items, ["国语/a.mp3", "国语/子/b.mp3", "other.mp3"])
        XCTAssertEqual(store.favorites, ["国语/a.mp3"])
        XCTAssertEqual(store.playlists[0].updatedAt, before, "路径校正不算编辑歌单")
        // 落盘：另一个 store 读到的是新路径
        let again = attachedPlaylists()
        XCTAssertEqual(again.playlists[0].items, ["国语/a.mp3", "国语/子/b.mp3", "other.mp3"])
        XCTAssertEqual(again.favorites, ["国语/a.mp3"])
    }

    func testPlaylistStoreApplyMovesSingleSongRename() throws {
        let store = attachedPlaylists()
        let list = try store.create(name: "L")
        try store.add(["a.mp3", "b.mp3"], to: list.id)
        try store.applyMoves([PathChange(old: "a.mp3", new: "z.mp3", isFolder: false)])
        XCTAssertEqual(store.playlists[0].items, ["z.mp3", "b.mp3"], "位置保持不变")
    }

    func testPlaylistStoreApplyMovesNoMatchDoesNotWrite() throws {
        let store = attachedPlaylists()
        let list = try store.create(name: "L")
        try store.add(["a.mp3"], to: list.id)
        let file = docs.appending(path: ".kapi/playlists.json")
        let before = try Data(contentsOf: file)
        try store.applyMoves([PathChange(old: "nope.mp3", new: "z.mp3", isFolder: false)])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testPlaylistStoreApplyMovesReadOnlyThrows() throws {
        let dir = docs.appending(path: ".kapi", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"version":999,"playlists":[]}"#.write(to: dir.appending(path: "playlists.json"), atomically: true, encoding: .utf8)
        let store = attachedPlaylists()
        XCTAssertThrowsError(try store.applyMoves([PathChange(old: "a", new: "b", isFolder: false)])) {
            XCTAssertEqual($0 as? PlaylistError, .readOnly)
        }
    }

    // MARK: 歌词微调

    func testLyricOffsetRemapped() {
        let entries = [LyricOffsetEntry(path: "华语/a.mp3", size: 1, offsetMs: 500),
                       LyricOffsetEntry(path: "other.mp3", size: 2, offsetMs: -200)]
        let out = LyricOffsetStore.remapped(entries, by: [PathChange(old: "华语", new: "国语", isFolder: true)])
        XCTAssertEqual(out.map(\.path), ["other.mp3", "国语/a.mp3"], "按路径排序")
        XCTAssertEqual(out.first { $0.path == "国语/a.mp3" }?.offsetMs, 500)
        XCTAssertEqual(out.first { $0.path == "国语/a.mp3" }?.size, 1)
    }

    func testLyricOffsetStoreApplyMovesPersists() throws {
        let store = LyricOffsetStore()
        store.attach(documentsURL: docs)
        try store.setOffset(500, for: track("a/s.mp3"))
        try store.applyMoves([PathChange(old: "a/s.mp3", new: "b/t.mp3", isFolder: false)])
        XCTAssertEqual(store.offsetMs(for: "b/t.mp3"), 500)
        XCTAssertEqual(store.offsetMs(for: "a/s.mp3"), 0)
        let again = LyricOffsetStore()
        again.attach(documentsURL: docs)
        XCTAssertEqual(again.offsetMs(for: "b/t.mp3"), 500)
    }

    // MARK: 播放队列

    func testPlayerFollowRewritesQueueAndCurrentTrack() {
        let player = PlayerService()
        let tracks = [track("华语/a.mp3"), track("华语/b.mp3"), track("c.mp3")]
        player.play(tracks: tracks, startAt: 0)
        player.pause()
        player.follow([PathChange(old: "华语", new: "国语", isFolder: true)], documentsURL: docs)
        XCTAssertEqual(player.queue.map(\.path), ["国语/a.mp3", "国语/b.mp3", "c.mp3"])
        XCTAssertEqual(player.currentTrack?.path, "国语/a.mp3")
        XCTAssertEqual(player.currentTrack?.url, docs.appending(path: "国语/a.mp3"))
        XCTAssertEqual(player.currentTrack?.title, "华语/a.mp3", "其余字段保留")
    }
}
