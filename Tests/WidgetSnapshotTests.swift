import XCTest
import UIKit
import SwiftUI
@testable import Kapi

/// 小组件的纯逻辑：快照往返与等价判断、时间线、点击链接、封面缩图、按钮命令总线
final class WidgetSnapshotTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "KapiWidgetTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func playing(
        path: String = "a.mp3", isPlaying: Bool = true, duration: TimeInterval = 200,
        position: TimeInterval = 50, updatedAt: Date? = nil, hasCover: Bool = false
    ) -> WidgetSnapshot.NowPlaying {
        WidgetSnapshot.NowPlaying(trackPath: path, title: "歌", artist: "人", isPlaying: isPlaying,
                                  duration: duration, position: position,
                                  updatedAt: updatedAt ?? t0, hasCover: hasCover)
    }

    private func snapshot(_ np: WidgetSnapshot.NowPlaying?, skin: String = "light") -> WidgetSnapshot {
        WidgetSnapshot(skin: skin, nowPlaying: np)
    }

    // MARK: 落盘

    func testWriteThenReadRoundTrips() throws {
        let original = snapshot(playing(hasCover: true), skin: "dark")
        try WidgetStore.write(original, to: dir)
        XCTAssertEqual(WidgetStore.read(from: dir), original)
    }

    func testReadMissingFileIsNil() {
        XCTAssertNil(WidgetStore.read(from: dir))
    }

    func testReadCorruptFileIsNil() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(to: WidgetStore.snapshotURL(in: dir)!, atomically: true, encoding: .utf8)
        XCTAssertNil(WidgetStore.read(from: dir))
    }

    func testReadNewerVersionIsNil() throws {
        var newer = snapshot(playing())
        newer.version = WidgetSnapshot.currentVersion + 1
        try WidgetStore.write(newer, to: dir)
        XCTAssertNil(WidgetStore.read(from: dir))
    }

    func testWriteWithoutContainerThrows() {
        XCTAssertThrowsError(try WidgetStore.write(snapshot(nil), to: nil))
    }

    // MARK: 等价判断（决定要不要重写、重刷）

    func testIdleSnapshotsAreEquivalent() {
        XCTAssertTrue(snapshot(nil).isEquivalent(to: snapshot(nil)))
    }

    func testIdleVersusPlayingIsDifferent() {
        XCTAssertFalse(snapshot(playing()).isEquivalent(to: snapshot(nil)))
        XCTAssertFalse(snapshot(nil).isEquivalent(to: snapshot(playing())))
    }

    func testPlayingProgressingNaturallyIsEquivalent() {
        let old = snapshot(playing(position: 50, updatedAt: t0))
        // 10 秒后自然走到 60：不是 seek，不用刷新
        let new = snapshot(playing(position: 60, updatedAt: t0.addingTimeInterval(10)))
        XCTAssertTrue(new.isEquivalent(to: old, at: t0.addingTimeInterval(10)))
    }

    func testSeekWhilePlayingIsDifferent() {
        let old = snapshot(playing(position: 50, updatedAt: t0))
        let new = snapshot(playing(position: 120, updatedAt: t0.addingTimeInterval(10)))
        XCTAssertFalse(new.isEquivalent(to: old, at: t0.addingTimeInterval(10)))
    }

    func testPausedPositionDoesNotDrift() {
        let old = snapshot(playing(isPlaying: false, position: 50, updatedAt: t0))
        // 暂停时 10 秒后位置还是 50：没变
        XCTAssertTrue(snapshot(playing(isPlaying: false, position: 50, updatedAt: t0.addingTimeInterval(10)))
            .isEquivalent(to: old, at: t0.addingTimeInterval(10)))
        // 暂停时拖到 120：变了
        XCTAssertFalse(snapshot(playing(isPlaying: false, position: 120, updatedAt: t0.addingTimeInterval(10)))
            .isEquivalent(to: old, at: t0.addingTimeInterval(10)))
    }

    func testPlayStateTrackAndCoverChangesAreDifferent() {
        let base = snapshot(playing())
        XCTAssertFalse(snapshot(playing(isPlaying: false)).isEquivalent(to: base))
        XCTAssertFalse(snapshot(playing(path: "b.mp3")).isEquivalent(to: base))
        XCTAssertFalse(snapshot(playing(hasCover: true)).isEquivalent(to: base))
        XCTAssertFalse(snapshot(playing(duration: 300)).isEquivalent(to: base))
    }

    func testSkinChangeIsDifferent() {
        XCTAssertFalse(snapshot(playing(), skin: "dark").isEquivalent(to: snapshot(playing(), skin: "light")))
    }

    // MARK: 时间线

    func testPlanWithoutSnapshotIsIdle() {
        XCTAssertEqual(WidgetTimeline.plan(nil, now: t0), [WidgetTimelinePoint(date: t0, display: .idle)])
        XCTAssertEqual(WidgetTimeline.plan(snapshot(nil), now: t0).map(\.display), [.idle])
    }

    func testPlanNewerVersionIsIdle() {
        var newer = snapshot(playing())
        newer.version = WidgetSnapshot.currentVersion + 1
        XCTAssertEqual(WidgetTimeline.plan(newer, now: t0).map(\.display), [.idle])
    }

    func testPlanPlayingHasRunningThenIdleAtEnd() {
        // 50 秒时写的快照，总长 200：起点 = t0 - 50，终点 = t0 + 150
        let np = playing(duration: 200, position: 50, updatedAt: t0)
        let plan = WidgetTimeline.plan(snapshot(np), now: t0.addingTimeInterval(10))
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].date, t0.addingTimeInterval(10))
        XCTAssertEqual(plan[0].display, .track(np, .running(t0.addingTimeInterval(-50)...t0.addingTimeInterval(150))))
        XCTAssertEqual(plan[1].date, t0.addingTimeInterval(150 + WidgetTimeline.idleGrace))
        XCTAssertEqual(plan[1].display, .idle)
    }

    func testPlanPlayingAfterExpectedEndIsIdle() {
        let np = playing(duration: 200, position: 50, updatedAt: t0)
        let late = t0.addingTimeInterval(150 + WidgetTimeline.idleGrace + 1)
        XCTAssertEqual(WidgetTimeline.plan(snapshot(np), now: late).map(\.display), [.idle])
    }

    func testPlanPausedShowsFractionThenExpires() {
        let np = playing(isPlaying: false, duration: 200, position: 50, updatedAt: t0)
        let plan = WidgetTimeline.plan(snapshot(np), now: t0.addingTimeInterval(60))
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].display, .track(np, .paused(fraction: 0.25)))
        XCTAssertEqual(plan[1].date, t0.addingTimeInterval(WidgetTimeline.pausedLifetime))
        XCTAssertEqual(plan[1].display, .idle)
    }

    func testPlanPausedPastLifetimeIsIdle() {
        let np = playing(isPlaying: false, updatedAt: t0)
        let late = t0.addingTimeInterval(WidgetTimeline.pausedLifetime + 1)
        XCTAssertEqual(WidgetTimeline.plan(snapshot(np), now: late).map(\.display), [.idle])
    }

    func testPlanUnknownDurationHasNoProgress() {
        let np = playing(isPlaying: true, duration: 0, position: 0, updatedAt: t0)
        let plan = WidgetTimeline.plan(snapshot(np), now: t0)
        XCTAssertEqual(plan[0].display, .track(np, .unknown))
        XCTAssertEqual(plan[1].date, t0.addingTimeInterval(WidgetTimeline.unknownLifetime))
    }

    func testPausedFractionIsClamped() {
        let np = playing(isPlaying: false, duration: 100, position: 999, updatedAt: t0)
        XCTAssertEqual(WidgetTimeline.plan(snapshot(np), now: t0)[0].display, .track(np, .paused(fraction: 1)))
    }

    // MARK: 点击链接

    func testLinksParse() {
        XCTAssertEqual(WidgetLink.action(for: WidgetLink.player), .openPlayer)
        XCTAssertEqual(WidgetLink.action(for: WidgetLink.playFavorites), .playFavorites)
        XCTAssertEqual(WidgetLink.action(for: URL(string: "kapi://player/")!), .openPlayer)
    }

    func testUnknownLinksAreIgnored() {
        XCTAssertNil(WidgetLink.action(for: URL(string: "https://example.com/player")!))
        XCTAssertNil(WidgetLink.action(for: URL(string: "kapi://delete/everything")!))
        XCTAssertNil(WidgetLink.action(for: URL(string: "kapi://favorites")!))
        XCTAssertNil(WidgetLink.action(for: URL(string: "kapi://favorites/delete")!))
    }

    // MARK: 封面缩图

    func testThumbnailShrinksLongestSide() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        }
        let data = try XCTUnwrap(WidgetBridge.thumbnailJPEG(from: big, maxPixel: 360))
        let thumb = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(thumb.size.width * thumb.scale, 360, accuracy: 1)
        XCTAssertEqual(thumb.size.height * thumb.scale, 240, accuracy: 1)
    }

    func testThumbnailDoesNotUpscale() throws {
        let small = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let data = try XCTUnwrap(WidgetBridge.thumbnailJPEG(from: small, maxPixel: 360))
        let thumb = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(thumb.size.width * thumb.scale, 100, accuracy: 1)
    }

    func testThumbnailOfEmptyImageIsNil() {
        XCTAssertNil(WidgetBridge.thumbnailJPEG(from: UIImage(), maxPixel: 360))
    }

    // MARK: 色板

    func testPaletteFollowsSkinNotSystem() {
        // Color → UIColor 经过 Float，和直接用 Double 算的有 1e-8 量级的差，所以带容差比较
        func assertColor(_ color: Color, equals hex: UInt32, file: StaticString = #filePath, line: UInt = #line) {
            let actual = UIColor(color).cgColor.components ?? []
            let expected = UIColor(hex: hex).cgColor.components ?? []
            XCTAssertEqual(actual.count, expected.count, file: file, line: line)
            for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: 0.001, file: file, line: line) }
        }
        assertColor(Theme.palette(.light).accent, equals: 0x6F4E37)
        assertColor(Theme.palette(.dark).accent, equals: 0xCDEB5A)
        assertColor(Theme.palette(.light).bg, equals: 0xF6F2EA)
        assertColor(Theme.palette(.dark).bg, equals: 0x0D0F13)
    }

    // MARK: 命令总线

    @MainActor
    func testCommandBusDeliversToHandler() {
        var received: [PlaybackCommandBus.Command] = []
        PlaybackCommandBus.handler = { received.append($0) }
        defer { PlaybackCommandBus.handler = nil }
        PlaybackCommandBus.send(.next)
        PlaybackCommandBus.send(.togglePlayPause)
        XCTAssertEqual(received, [.next, .togglePlayPause])
    }

    @MainActor
    func testCommandBusWithoutHandlerIsNoOp() {
        PlaybackCommandBus.handler = nil
        PlaybackCommandBus.send(.previous)
    }
}
