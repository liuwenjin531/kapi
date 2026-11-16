import XCTest
@testable import Kapi

/// 歌单 JSON 的编解码往返与向后兼容，纯逻辑、不依赖 iCloud
final class PlaylistCodingTests: XCTestCase {
    func testRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let list = Playlist(id: UUID(), name: "通勤路上", cover: "covers/x.jpg",
                            items: ["华语/夜航船.flac", "旅行路上/国道 318.mp3"],
                            createdAt: date, updatedAt: date, lastPlayedAt: nil)
        let data = try PlaylistCoding.makeEncoder().encode(PlaylistsFile(playlists: [list]))
        let back = try PlaylistCoding.makeDecoder().decode(PlaylistsFile.self, from: data)
        XCTAssertEqual(back.version, PlaylistsFile.currentVersion)
        XCTAssertEqual(back.playlists, [list])
    }

    func testDecodeDocumentExample() throws {
        // 一份旧版文件的原文，防止字段名被改动后悄悄读不出旧文件
        let json = """
        {"version":1,"playlists":[{"id":"4E1C2B9A-0000-0000-0000-000000000000","name":"通勤路上",
        "cover":"covers/4E1C2B9A-0000-0000-0000-000000000000.jpg","items":["华语/夜航船.flac"],
        "createdAt":"2026-11-12T22:00:00Z","updatedAt":"2026-11-12T22:10:00Z","lastPlayedAt":null}]}
        """
        let file = try PlaylistCoding.makeDecoder().decode(PlaylistsFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.playlists.first?.name, "通勤路上")
        XCTAssertNil(file.playlists.first?.lastPlayedAt)
    }

    func testFavoritesRoundTrip() throws {
        let data = try PlaylistCoding.makeEncoder().encode(FavoritesFile(items: ["a/b.mp3"]))
        let back = try PlaylistCoding.makeDecoder().decode(FavoritesFile.self, from: data)
        XCTAssertEqual(back.items, ["a/b.mp3"])
    }
}

/// 文件夹树：递归统计与建树
final class FolderNodeBasicTests: XCTestCase {
    private func track(_ path: String, size: Int64) -> Track {
        Track(path: path, url: URL(fileURLWithPath: "/x/" + path), title: path, artist: nil,
              duration: 0, fileSize: size, format: "MP3", hasVideo: false, videoAspect: nil,
              createdAt: .distantPast, isDownloaded: true)
    }

    func testRecursiveCounts() {
        let root = FolderNode.build(from: [
            track("a.mp3", size: 10), track("华语/b.mp3", size: 20), track("华语/怀旧/c.mp3", size: 30),
        ], folderPaths: ["空文件夹"])
        XCTAssertEqual(root.trackCount, 3)
        XCTAssertEqual(root.totalSize, 60)
        XCTAssertEqual(root.subfolders.map(\.name).sorted(), ["华语", "空文件夹"])
        XCTAssertEqual(root.subfolders.first { $0.name == "华语" }?.trackCount, 2)
        XCTAssertEqual(root.coverTracks(limit: 2).count, 2)
    }
}
