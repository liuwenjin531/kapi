import XCTest
@testable import Kapi

/// 文件夹页排序、搜索最近记录与歌单匹配、导入提示文案
final class FolderSortingTests: XCTestCase {
    private func track(_ title: String, format: String = "MP3", size: Int64 = 1, created: TimeInterval = 0) -> Track {
        Track(path: "\(title).\(format.lowercased())", url: URL(filePath: "/d/\(title)"), title: title, artist: nil,
              duration: 0, fileSize: size, format: format, hasVideo: false, videoAspect: nil,
              createdAt: Date(timeIntervalSince1970: created), isDownloaded: true)
    }

    func testNameSortIsNumericAware() {
        let sorted = FolderSorting.tracks([track("10"), track("2"), track("1")], by: .name)
        XCTAssertEqual(sorted.map(\.title), ["1", "2", "10"])
    }

    func testSizeAndDateSortDescending() {
        let a = track("a", size: 10, created: 300), b = track("b", size: 30, created: 100), c = track("c", size: 20, created: 200)
        XCTAssertEqual(FolderSorting.tracks([a, b, c], by: .size).map(\.title), ["b", "c", "a"])
        XCTAssertEqual(FolderSorting.tracks([a, b, c], by: .dateAdded).map(\.title), ["a", "c", "b"])
    }

    func testTypeSortFallsBackToName() {
        let sorted = FolderSorting.tracks(
            [track("z", format: "FLAC"), track("b", format: "MP3"), track("a", format: "MP3")], by: .type)
        XCTAssertEqual(sorted.map(\.title), ["z", "a", "b"])
    }

    func testFolderSort() {
        let root = FolderNode.build(from: [
            track("x", size: 5).withPath("b/x.mp3"), track("y", size: 50).withPath("a/y.mp3"),
        ])
        XCTAssertEqual(FolderSorting.folders(root.subfolders, by: .name).map(\.name), ["a", "b"])
        XCTAssertEqual(FolderSorting.folders(root.subfolders, by: .size).map(\.name), ["a", "b"])
        XCTAssertEqual(FolderSorting.folders(root.subfolders.reversed(), by: .dateAdded).map(\.name), ["a", "b"])
    }

    func testRecentsDedupeAndLimit() {
        var list: [String] = []
        for i in 0..<12 { list = SearchLogic.adding("q\(i)", to: list) }
        XCTAssertEqual(list.count, SearchLogic.maxRecents)
        XCTAssertEqual(list.first, "q11")
        list = SearchLogic.adding(" Q5 ", to: list)
        XCTAssertEqual(list.first, "Q5")
        XCTAssertEqual(list.filter { $0.lowercased() == "q5" }.count, 1)
        XCTAssertEqual(SearchLogic.adding("   ", to: list), list)
    }

    func testRecentsRoundTrip() {
        let list = ["夜", "a b"]
        XCTAssertEqual(SearchLogic.decode(SearchLogic.encode(list)), list)
        XCTAssertEqual(SearchLogic.decode(""), [])
    }

    func testPlaylistMatching() {
        let now = Date()
        func pl(_ n: String) -> Playlist {
            Playlist(id: UUID(), name: n, cover: nil, items: [], createdAt: now, updatedAt: now, lastPlayedAt: nil)
        }
        let hits = SearchLogic.matchingPlaylists([pl("通勤路上"), pl("Night Drive"), pl("跑步")], query: "night")
        XCTAssertEqual(hits.map(\.name), ["Night Drive"])
        XCTAssertTrue(SearchLogic.matchingPlaylists([pl("a")], query: " ").isEmpty)
    }

    func testPathText() {
        XCTAssertEqual(SearchLogic.pathText(""), "乐库")
        XCTAssertEqual(SearchLogic.pathText("华语/怀旧"), "华语 › 怀旧")
    }

    func testImportSummary() {
        XCTAssertEqual(ImportSummary.message(imported: 3, skipped: 0, failed: 0), "已导入 3 首")
        XCTAssertEqual(ImportSummary.message(imported: 3, skipped: 1, failed: 2), "已导入 3 首，跳过 1 个（不是音频或视频），失败 2 个")
        XCTAssertEqual(ImportSummary.message(imported: 0, skipped: 0, failed: 1), "失败 1 个")
        XCTAssertEqual(ImportSummary.message(imported: 0, skipped: 0, failed: 0), "已导入 0 首")
    }
}

private extension Track {
    func withPath(_ p: String) -> Track {
        Track(path: p, url: url, title: title, artist: nil, duration: 0, fileSize: fileSize, format: format,
              hasVideo: false, videoAspect: nil, createdAt: createdAt, isDownloaded: true)
    }
}
