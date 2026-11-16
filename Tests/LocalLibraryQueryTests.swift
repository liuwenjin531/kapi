import XCTest
@testable import Kapi

/// 本机乐库遍历：路径、隐藏目录、文件夹标记、下载状态
final class LocalLibraryQueryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "LocalLibraryQueryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: ".kapi"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "空"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: root.appending(path: "a.mp3"))
        try Data(repeating: 2, count: 20).write(to: root.appending(path: "sub/b.m4a"))
        try Data("{}".utf8).write(to: root.appending(path: ".kapi/x.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)  // 临时目录，删不掉也无妨
    }

    func testEnumerateListsFilesAndFoldersWithRelativePaths() {
        let items = LocalLibraryQuery.enumerate(documentsURL: root)
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })

        XCTAssertEqual(Set(byPath.keys), ["a.mp3", "sub", "sub/b.m4a", "空"])
        XCTAssertEqual(byPath["a.mp3"]?.fileSize, 10)
        XCTAssertEqual(byPath["sub/b.m4a"]?.fileSize, 20)
        XCTAssertEqual(byPath["sub"]?.isFolder, true)
        XCTAssertEqual(byPath["空"]?.isFolder, true)
        XCTAssertEqual(byPath["a.mp3"]?.isFolder, false)
    }

    func testEnumerateSkipsHiddenKapiFolder() {
        let items = LocalLibraryQuery.enumerate(documentsURL: root)
        XCTAssertFalse(items.contains { $0.path.hasPrefix(".kapi") })
    }

    func testLocalFilesAreAlwaysDownloaded() {
        let items = LocalLibraryQuery.enumerate(documentsURL: root)
        XCTAssertTrue(items.allSatisfy { $0.isDownloaded && $0.downloadFraction == nil })
    }

    func testEnumerateMissingRootReturnsEmpty() {
        XCTAssertEqual(LocalLibraryQuery.enumerate(documentsURL: root.appending(path: "不存在")), [])
    }
}
