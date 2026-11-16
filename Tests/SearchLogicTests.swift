import XCTest
@testable import Kapi

/// 搜索分类筛选、最近搜索删除、方格列数
final class SearchLogicTests: XCTestCase {
    func testCountsPerCategory() {
        let counts = SearchCounts(playlists: 1, folders: 2, tracks: 7)
        XCTAssertEqual(counts.count(for: .all), 10)
        XCTAssertEqual(counts.count(for: .playlists), 1)
        XCTAssertEqual(counts.count(for: .folders), 2)
        XCTAssertEqual(counts.count(for: .tracks), 7)
    }

    func testCategoryShows() {
        XCTAssertTrue(SearchCategory.all.shows(.folders))
        XCTAssertTrue(SearchCategory.folders.shows(.folders))
        XCTAssertFalse(SearchCategory.folders.shows(.tracks))
        XCTAssertFalse(SearchCategory.playlists.shows(.folders))
    }

    func testRemovingRecentIgnoresCase() {
        XCTAssertEqual(SearchLogic.removing("abc", from: ["ABC", "夜", "x"]), ["夜", "x"])
        XCTAssertEqual(SearchLogic.removing("无", from: ["夜"]), ["夜"])
    }

    func testGridColumns() {
        XCTAssertEqual(FolderGridColumns.count(width: 393, isWide: false), 2)
        XCTAssertEqual(FolderGridColumns.count(width: 570, isWide: true), 4)
        XCTAssertEqual(FolderGridColumns.count(width: 700, isWide: true), 4)
        XCTAssertEqual(FolderGridColumns.count(width: 800, isWide: true), 6)
        XCTAssertEqual(FolderGridColumns.count(width: 100, isWide: true), 2)
    }
}
