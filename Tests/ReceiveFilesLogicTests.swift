import XCTest
@testable import Kapi

/// 「收到文件」的纯逻辑：批次合并、名单截断、默认文件夹、来源判断、Inbox 跳过
final class ReceiveFilesLogicTests: XCTestCase {
    func testMergeAppendsAndDedupes() {
        let a = URL(filePath: "/tmp/x/a.mp3")
        let b = URL(filePath: "/tmp/x/b.mp3")
        var batch = ReceiveFilesLogic.merge([], with: [a])
        batch = ReceiveFilesLogic.merge(batch, with: [b, a, URL(filePath: "/tmp/x/../x/a.mp3")])
        XCTAssertEqual(batch.map(\.lastPathComponent), ["a.mp3", "b.mp3"])
    }

    func testSummarizeTruncates() {
        let names = (1...8).map { "\($0).mp3" }
        let s = ReceiveFilesLogic.summarize(names: names, limit: 5)
        XCTAssertEqual(s.shown.count, 5)
        XCTAssertEqual(s.more, 3)
        let all = ReceiveFilesLogic.summarize(names: Array(names.prefix(5)), limit: 5)
        XCTAssertEqual(all.more, 0)
        XCTAssertEqual(all.shown.count, 5)
    }

    func testInitialFolderFallsBackToRoot() {
        XCTAssertEqual(ReceiveFilesLogic.initialFolder(saved: "华语/老歌") { _ in true }, "华语/老歌")
        XCTAssertEqual(ReceiveFilesLogic.initialFolder(saved: "华语/老歌") { _ in false }, "")
        XCTAssertEqual(ReceiveFilesLogic.initialFolder(saved: nil) { _ in true }, "")
        XCTAssertEqual(ReceiveFilesLogic.initialFolder(saved: "") { _ in true }, "")
    }

    func testFolderTitle() {
        XCTAssertEqual(ReceiveFilesLogic.folderTitle(""), "乐库")
        XCTAssertEqual(ReceiveFilesLogic.folderTitle("华语/老歌"), "乐库 › 华语 › 老歌")
    }

    func testLastFolderKeySeparatesLocations() {
        XCTAssertNotEqual(ReceiveFilesLogic.lastFolderKey(location: .icloud),
                          ReceiveFilesLogic.lastFolderKey(location: .local))
    }

    func testOriginAndRemovable() {
        let docs = URL(filePath: "/tmp/docs")
        let inbox = docs.appending(path: "Inbox")
        let share = URL(filePath: "/tmp/group/Inbox")
        let sys = inbox.appending(path: "a.mp3")
        let shared = share.appending(path: "UUID1/b.mp3")
        let sharedFailed = share.appending(path: "UUID2/c.mp3")
        let external = URL(filePath: "/tmp/other/d.mp3")
        XCTAssertEqual(ReceiveFilesLogic.origin(of: sys, systemInbox: inbox, shareInbox: share), .systemInbox)
        XCTAssertEqual(ReceiveFilesLogic.origin(of: shared, systemInbox: inbox, shareInbox: share), .shareInbox)
        XCTAssertEqual(ReceiveFilesLogic.origin(of: external, systemInbox: inbox, shareInbox: share), .external)
        XCTAssertEqual(ReceiveFilesLogic.origin(of: shared, systemInbox: inbox, shareInbox: nil), .external)

        let removable = ReceiveFilesLogic.removable(
            all: [sys, shared, sharedFailed, external], failed: [sharedFailed, sys],
            systemInbox: inbox, shareInbox: share
        )
        // 系统 Inbox 的失败也删，分享收件箱的失败留着，别处原件不动
        XCTAssertEqual(removable, [sys, shared])
    }

    func testSystemInboxPath() {
        XCTAssertTrue(ReceiveFilesLogic.isSystemInboxPath("Inbox"))
        XCTAssertTrue(ReceiveFilesLogic.isSystemInboxPath("Inbox/a.mp3"))
        XCTAssertFalse(ReceiveFilesLogic.isSystemInboxPath("Inbox2"))
        XCTAssertFalse(ReceiveFilesLogic.isSystemInboxPath("华语/Inbox"))
    }

    func testEnumerateSkipsRootInbox() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ReceiveInbox-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }  // 临时目录，删不掉也无妨
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "Inbox"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "华语/Inbox"), withIntermediateDirectories: true)
        try Data(count: 5).write(to: root.appending(path: "Inbox/new.mp3"))
        try Data(count: 5).write(to: root.appending(path: "华语/Inbox/keep.mp3"))
        let paths = Set(LocalLibraryQuery.enumerate(documentsURL: root).map(\.path))
        XCTAssertEqual(paths, ["华语", "华语/Inbox", "华语/Inbox/keep.mp3"])
    }

    @MainActor
    func testReceivedFilesBatchesIntoOnePresentation() async throws {
        let store = ReceivedFiles()
        store.add([URL(filePath: "/tmp/r/1.mp3")])
        store.add([URL(filePath: "/tmp/r/2.mp3")])
        XCTAssertFalse(store.isPresented)
        try await Task.sleep(for: ReceivedFiles.settleDelay + .milliseconds(300))
        XCTAssertTrue(store.isPresented)
        XCTAssertEqual(store.urls.count, 2)
        // 弹出后又来的文件追加进同一批，不重新计时
        store.add([URL(filePath: "/tmp/r/3.mp3")])
        XCTAssertTrue(store.isPresented)
        XCTAssertEqual(store.urls.count, 3)
        store.dismiss()
        XCTAssertFalse(store.isPresented)
        XCTAssertTrue(store.urls.isEmpty)
    }
}
