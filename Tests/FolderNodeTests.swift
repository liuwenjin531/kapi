import XCTest
@testable import Kapi

/// 文件夹树的建立、递归统计、查找
final class FolderNodeTests: XCTestCase {
    static func track(_ path: String, size: Int64 = 100) -> Track {
        Track(path: path, url: URL(filePath: "/docs/" + path), title: path, artist: nil, duration: 0,
              fileSize: size, format: "MP3", hasVideo: false, videoAspect: nil,
              createdAt: Date(timeIntervalSince1970: 0), isDownloaded: true)
    }

    func testBuildGroupsTracksByFolder() {
        let root = FolderNode.build(from: [
            Self.track("a.mp3"), Self.track("华语/b.mp3"), Self.track("华语/怀旧/c.mp3", size: 300),
        ])
        XCTAssertTrue(root.isRoot)
        XCTAssertEqual(root.name, "乐库")
        XCTAssertEqual(root.tracks.map(\.path), ["a.mp3"])
        XCTAssertEqual(root.subfolders.map(\.path), ["华语"])
        let sub = root.subfolders[0]
        XCTAssertEqual(sub.name, "华语")
        XCTAssertEqual(sub.tracks.map(\.path), ["华语/b.mp3"])
        XCTAssertEqual(sub.subfolders.map(\.path), ["华语/怀旧"])
    }

    func testRecursiveStats() {
        let root = FolderNode.build(from: [
            Self.track("a.mp3", size: 1), Self.track("x/b.mp3", size: 20), Self.track("x/y/c.mp3", size: 300),
        ])
        XCTAssertEqual(root.trackCount, 3)
        XCTAssertEqual(root.totalSize, 321)
        let x = root.subfolders[0]
        XCTAssertEqual(x.trackCount, 2)
        XCTAssertEqual(x.totalSize, 320)
    }

    func testEmptyFoldersAreKept() {
        // 用户刚新建的空文件夹没有歌，只能靠 folderPaths 留住，包括它的各级父目录
        let root = FolderNode.build(from: [Self.track("a.mp3")], folderPaths: ["新建/子夹"])
        XCTAssertEqual(root.subfolders.map(\.path), ["新建"])
        XCTAssertEqual(root.subfolders[0].subfolders.map(\.path), ["新建/子夹"])
        XCTAssertEqual(root.subfolders[0].subfolders[0].trackCount, 0)
    }

    func testEmptyTreeIsJustRoot() {
        let root = FolderNode.build(from: [])
        XCTAssertTrue(root.subfolders.isEmpty)
        XCTAssertTrue(root.tracks.isEmpty)
        XCTAssertEqual(root.trackCount, 0)
    }

    func testNaturalSorting() {
        // 数字按数值排（2 在 10 前），不是按字符串
        let root = FolderNode.build(from: [
            Self.track("10.mp3"), Self.track("2.mp3"), Self.track("d10/x.mp3"), Self.track("d2/x.mp3"),
        ])
        XCTAssertEqual(root.tracks.map(\.fileName), ["2.mp3", "10.mp3"])
        XCTAssertEqual(root.subfolders.map(\.name), ["d2", "d10"])
    }

    func testAllTracksOrderAndCoverTracks() {
        let root = FolderNode.build(from: [
            Self.track("a.mp3"), Self.track("b/c.mp3"), Self.track("b/d.mp3"), Self.track("e.mp3"), Self.track("b/f/g.mp3"),
        ])
        // 先本层的歌，再依次进子文件夹
        XCTAssertEqual(root.allTracks.map(\.path), ["a.mp3", "e.mp3", "b/c.mp3", "b/d.mp3", "b/f/g.mp3"])
        XCTAssertEqual(root.coverTracks(limit: 3).map(\.path), ["a.mp3", "e.mp3", "b/c.mp3"])
    }

    @MainActor
    func testStoreLookupAndSearch() {
        let store = LibraryStore()
        XCTAssertFalse(store.hasLoaded)
        store.replace(root: FolderNode.build(from: [
            Self.track("华语/夜航船.flac"), Self.track("华语/怀旧/老歌.mp3"),
        ]))
        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(store.node(at: "")?.isRoot, true)
        XCTAssertEqual(store.node(at: "华语/怀旧")?.name, "怀旧")
        XCTAssertNil(store.node(at: "不存在"))
        XCTAssertEqual(store.track(at: "华语/怀旧/老歌.mp3")?.fileName, "老歌.mp3")
        let found = store.search("怀旧")
        XCTAssertEqual(found.folders.map(\.path), ["华语/怀旧"])
        XCTAssertTrue(store.search("  ").isEmpty)
    }

    @MainActor
    func testDownloadProgressStaysUnchangedWhenEqual() {
        let store = LibraryStore()
        store.updateDownloadProgress(["a.mp3": 0.5])
        XCTAssertEqual(store.downloadProgress, ["a.mp3": 0.5])
        store.updateDownloadProgress([:])
        XCTAssertTrue(store.downloadProgress.isEmpty)
    }
}
