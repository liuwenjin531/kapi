import XCTest
@testable import Kapi

/// 扫描结果 → 文件夹树的转换，以及乐库文件操作的纯逻辑。不依赖 iCloud。
final class LibraryScanTests: XCTestCase {
    private let docs = URL(filePath: "/container/Documents")
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(_ path: String, folder: Bool = false, size: Int64 = 1000, downloaded: Bool = true,
                      fraction: Double? = nil, modified: Date? = nil) -> ScanItem {
        ScanItem(path: path, isFolder: folder, fileSize: size, createdAt: t0,
                 modifiedAt: modified ?? t0, isDownloaded: downloaded, downloadFraction: fraction)
    }

    private func build(_ items: [ScanItem], meta: [String: TrackMetadata] = [:]) -> LibrarySnapshot {
        LibraryScan.build(items: items, documentsURL: docs) { meta[$0] }
    }

    // MARK: 过滤

    func testOnlyKnownExtensionsBecomeTracks() {
        let snap = build([
            item("a.mp3"), item("b.FLAC"), item("c.mov"), item("d.lrc"), item("e.pdf"), item("noext"),
        ])
        XCTAssertEqual(snap.root.tracks.map(\.path), ["a.mp3", "b.FLAC", "c.mov"])
        XCTAssertEqual(snap.root.tracks.map(\.format), ["MP3", "FLAC", "MOV"])
    }

    func testHiddenItemsAndKapiFolderAreSkipped() {
        let snap = build([
            item(".kapi", folder: true), item(".kapi/covers/x.jpg"), item(".hidden.mp3"),
            item("音乐/.Trash/old.mp3"), item("音乐", folder: true), item("音乐/ok.mp3"),
        ])
        XCTAssertEqual(snap.root.allTracks.map(\.path), ["音乐/ok.mp3"])
        XCTAssertEqual(snap.root.subfolders.map(\.path), ["音乐"])
        XCTAssertTrue(snap.root.subfolders[0].subfolders.isEmpty)
    }

    func testEmptyFoldersSurviveAndDuplicatesCollapse() {
        let snap = build([item("空", folder: true), item("a.mp3"), item("a.mp3")])
        XCTAssertEqual(snap.root.subfolders.map(\.path), ["空"])
        XCTAssertEqual(snap.root.tracks.count, 1)
    }

    // MARK: 曲目字段

    func testTrackFieldsFromItem() {
        let snap = build([item("华语/夜航船.flac", size: 4321)])
        let track = snap.root.subfolders[0].tracks[0]
        XCTAssertEqual(track.title, "夜航船", "没读过标签时用去掉扩展名的文件名")
        XCTAssertEqual(track.url, docs.appending(path: "华语/夜航船.flac"))
        XCTAssertEqual(track.fileSize, 4321)
        XCTAssertEqual(track.duration, 0)
        XCTAssertNil(track.artist)
        XCTAssertEqual(track.folderPath, "华语")
        XCTAssertFalse(track.hasVideo)
        XCTAssertTrue(build([item("v.mp4")]).root.tracks[0].hasVideo, "没读过元数据时按扩展名猜视频")
    }

    func testCachedMetadataIsUsedOnlyWhenDownloadedAndKeyMatches() {
        let it = item("a.mp3", size: 5)
        let meta = TrackMetadata(title: "真标题", artist: "艺人", duration: 215, hasVideo: false, videoAspect: nil)
        let key = LibraryScan.cacheKey(for: it)

        let hit = build([it], meta: [key: meta]).root.tracks[0]
        XCTAssertEqual(hit.title, "真标题")
        XCTAssertEqual(hit.artist, "艺人")
        XCTAssertEqual(hit.duration, 215)

        // 没下载：即使缓存里有也不用（文件可能已被系统回收，且我们不该再去碰它）
        let cloud = build([item("a.mp3", size: 5, downloaded: false)], meta: [key: meta]).root.tracks[0]
        XCTAssertEqual(cloud.title, "a")
        XCTAssertFalse(cloud.isDownloaded)

        // 修改时间变了 -> 键变了 -> 缓存失效
        let changed = build([item("a.mp3", size: 5, modified: t0.addingTimeInterval(60))], meta: [key: meta]).root.tracks[0]
        XCTAssertEqual(changed.title, "a")
    }

    func testEmptyMetadataTitleFallsBackToFileName() {
        let it = item("x.mp3")
        let meta = TrackMetadata(title: "", artist: nil, duration: 1, hasVideo: false, videoAspect: nil)
        XCTAssertEqual(build([it], meta: [LibraryScan.cacheKey(for: it): meta]).root.tracks[0].title, "x")
    }

    func testVideoMetadataOverridesGuess() {
        let it = item("clip.mov")
        let meta = TrackMetadata(title: nil, artist: nil, duration: 9, hasVideo: false, videoAspect: nil)
        XCTAssertFalse(build([it], meta: [LibraryScan.cacheKey(for: it): meta]).root.tracks[0].hasVideo,
                       "读到的结果优先：.mov 也可能是纯音频")
    }

    // MARK: 下载进度

    func testDownloadProgressOnlyForUndownloadedWithFraction() {
        let snap = build([
            item("a.mp3", downloaded: false, fraction: 0.4),
            item("b.mp3", downloaded: false, fraction: nil),
            item("c.mp3", downloaded: true, fraction: 0.9),
            item("d.mp3", downloaded: false, fraction: 1.7),
        ])
        XCTAssertEqual(snap.downloadProgress, ["a.mp3": 0.4, "d.mp3": 1.0])
    }

    // MARK: 路径与键

    func testRelativePath() {
        let base = "/private/var/mobile/Containers/Data/iCloud~x/Documents"
        XCTAssertEqual(LibraryScan.relativePath(of: base + "/华语/a.mp3", under: base), "华语/a.mp3")
        // 查询结果和容器 URL 一个带 /private 一个不带
        XCTAssertEqual(LibraryScan.relativePath(of: "/var/mobile/Containers/Data/iCloud~x/Documents/a.mp3", under: base), "a.mp3")
        XCTAssertEqual(LibraryScan.relativePath(of: base + "/a.mp3", under: base + "/"), "a.mp3")
        XCTAssertNil(LibraryScan.relativePath(of: base, under: base), "根目录自己不算")
        XCTAssertNil(LibraryScan.relativePath(of: base + "2/a.mp3", under: base), "前缀相同但不是子路径")
        XCTAssertNil(LibraryScan.relativePath(of: "/elsewhere/a.mp3", under: base))
    }

    func testIsHidden() {
        XCTAssertTrue(LibraryScan.isHidden(".kapi/playlists.json"))
        XCTAssertTrue(LibraryScan.isHidden("a/.b/c.mp3"))
        XCTAssertTrue(LibraryScan.isHidden(".x.mp3"))
        XCTAssertFalse(LibraryScan.isHidden("a/b.c/d.mp3"), "只看每一级的开头")
    }

    func testCacheKeyChangesWithSizeAndMtime() {
        let a = LibraryScan.cacheKey(path: "a.mp3", fileSize: 1, modifiedAt: t0)
        XCTAssertNotEqual(a, LibraryScan.cacheKey(path: "a.mp3", fileSize: 2, modifiedAt: t0))
        XCTAssertNotEqual(a, LibraryScan.cacheKey(path: "a.mp3", fileSize: 1, modifiedAt: t0.addingTimeInterval(1)))
        XCTAssertNotEqual(a, LibraryScan.cacheKey(path: "b.mp3", fileSize: 1, modifiedAt: t0))
        XCTAssertEqual(a, LibraryScan.cacheKey(path: "a.mp3", fileSize: 1, modifiedAt: t0))
    }

    // MARK: 文件操作

    func testPathSafety() {
        XCTAssertTrue(LibraryFiles.isSafe(""))
        XCTAssertTrue(LibraryFiles.isSafe("华语/怀旧"))
        XCTAssertFalse(LibraryFiles.isSafe("../x"))
        XCTAssertFalse(LibraryFiles.isSafe("a/../../x"))
        XCTAssertFalse(LibraryFiles.isSafe("/etc"))
    }

    private func makeTempDocs() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "kapi-test-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testUniqueName() throws {
        let dir = try makeTempDocs()
        XCTAssertEqual(LibraryFiles.uniqueName(for: "a.mp3", in: dir, taken: []), "a.mp3")
        try Data().write(to: dir.appending(path: "a.mp3"))
        XCTAssertEqual(LibraryFiles.uniqueName(for: "a.mp3", in: dir, taken: []), "a 2.mp3")
        try Data().write(to: dir.appending(path: "a 2.mp3"))
        XCTAssertEqual(LibraryFiles.uniqueName(for: "a.mp3", in: dir, taken: []), "a 3.mp3")
        XCTAssertEqual(LibraryFiles.uniqueName(for: "b.mp3", in: dir, taken: ["b.mp3"]), "b 2.mp3", "同一批里已占用的名字也要避开")
        // iCloud 老式占位：云上有同名文件
        try Data().write(to: dir.appending(path: ".c.mp3.icloud"))
        XCTAssertEqual(LibraryFiles.uniqueName(for: "c.mp3", in: dir, taken: []), "c 2.mp3")
    }

    func testCreateFolder() async throws {
        let docs = try makeTempDocs()
        let files = LibraryFiles(documentsURL: docs)
        let path = try await files.createFolder(named: "  华语 ", in: "")
        XCTAssertEqual(path, "华语")
        let nested = try await files.createFolder(named: "怀旧", in: "华语")
        XCTAssertEqual(nested, "华语/怀旧")
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.appending(path: "华语/怀旧").path))

        for bad in ["", "  ", "a/b", "a:b", ".隐藏"] {
            do { _ = try await files.createFolder(named: bad, in: ""); XCTFail("应拒绝 \(bad)") }
            catch { XCTAssertEqual(error as? LibraryFiles.FileError, .invalidName) }
        }
        do { _ = try await files.createFolder(named: "华语", in: "") ; XCTFail("应报已存在") }
        catch { XCTAssertEqual(error as? LibraryFiles.FileError, .alreadyExists) }
        do { _ = try await files.createFolder(named: "x", in: "../out"); XCTFail("应拒绝越界路径") }
        catch { XCTAssertEqual(error as? LibraryFiles.FileError, .invalidPath) }
    }

    func testImportRenamesDuplicatesAndKeepsLyricsPaired() async throws {
        let docs = try makeTempDocs()
        let src = try makeTempDocs()
        let files = LibraryFiles(documentsURL: docs)
        try Data("old".utf8).write(to: docs.appending(path: "歌.mp3"))

        let song = src.appending(path: "歌.mp3"), lrc = src.appending(path: "歌.lrc")
        let pdf = src.appending(path: "说明.pdf")
        try Data("new".utf8).write(to: song)
        try Data("[00:01.00]词".utf8).write(to: lrc)
        try Data().write(to: pdf)

        let result = try await files.importFiles([lrc, song, pdf], into: "")
        XCTAssertEqual(Set(result.imported), [song, lrc])
        XCTAssertEqual(result.skipped, [pdf])
        XCTAssertTrue(result.failed.isEmpty)
        // 原有的不被覆盖；新歌改名「歌 2」，歌词跟着改成「歌 2.lrc」
        XCTAssertEqual(try String(contentsOf: docs.appending(path: "歌.mp3"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: docs.appending(path: "歌 2.mp3"), encoding: .utf8), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.appending(path: "歌 2.lrc").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appending(path: "说明.pdf").path))
    }

    func testImportIntoSubfolderCreatesItIfMissing() async throws {
        let docs = try makeTempDocs()
        let src = try makeTempDocs()
        let song = src.appending(path: "x.m4a")
        try Data("x".utf8).write(to: song)
        let result = try await LibraryFiles(documentsURL: docs).importFiles([song], into: "新/夹")
        XCTAssertEqual(result.imported, [song])
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.appending(path: "新/夹/x.m4a").path))
    }

    func testDeleteRemovesSongAndLyrics() async throws {
        let docs = try makeTempDocs()
        try FileManager.default.createDirectory(at: docs.appending(path: "d"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: docs.appending(path: "d/歌.mp3"))
        try Data("l".utf8).write(to: docs.appending(path: "d/歌.lrc"))
        try Data("o".utf8).write(to: docs.appending(path: "d/别的.mp3"))
        let track = FolderNodeTests.track("d/歌.mp3")

        try await LibraryFiles(documentsURL: docs).delete(track)
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appending(path: "d/歌.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appending(path: "d/歌.lrc").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.appending(path: "d/别的.mp3").path))
    }
}
