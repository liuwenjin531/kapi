import XCTest
@testable import Kapi

/// 状态文件的本地部分：没有文件、能读、写入往返、占位识别。不涉及真正的 iCloud
final class StateFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "KapiStateFileTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFile() {
        guard case .missing = StateFile.read(dir.appending(path: "none.json")) else {
            return XCTFail("文件不存在应当返回 missing")
        }
    }

    func testWriteThenRead() throws {
        // 子目录 .kapi 不存在时写入要自己建出来
        let url = dir.appending(path: ".kapi/playlists.json")
        let payload = Data("你好 kapi".utf8)
        try StateFile.write(payload, to: url)
        guard case .loaded(let data) = StateFile.read(url) else {
            return XCTFail("写入后应当能读到")
        }
        XCTAssertEqual(data, payload)
    }

    func testOverwriteReplacesContent() throws {
        let url = dir.appending(path: "favorites.json")
        try StateFile.write(Data("first".utf8), to: url)
        try StateFile.write(Data("second".utf8), to: url)
        guard case .loaded(let data) = StateFile.read(url) else { return XCTFail() }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "second")
    }

    /// 旧式 iCloud 占位：同目录下 `.名字.icloud`，真文件不在，必须判为「暂时读不到」
    func testOldStylePlaceholderIsUnavailable() throws {
        let url = dir.appending(path: "playlists.json")
        try Data().write(to: dir.appending(path: ".playlists.json.icloud"))
        XCTAssertTrue(isUnavailable(StateFile.read(url)))
    }

    /// 占位存在时不能当成「没有文件」，否则会新建一份空歌单覆盖云上的内容
    func testPlaceholderIsNotMissing() throws {
        let url = dir.appending(path: "favorites.json")
        try Data().write(to: dir.appending(path: ".favorites.json.icloud"))
        XCTAssertFalse(isMissing(StateFile.read(url)))
    }

    private func isUnavailable(_ result: StateFile.Read) -> Bool {
        if case .unavailable = result { return true }
        return false
    }

    private func isMissing(_ result: StateFile.Read) -> Bool {
        if case .missing = result { return true }
        return false
    }
}
