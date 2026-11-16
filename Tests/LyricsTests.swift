import XCTest
@testable import Kapi

/// `.lrc` 解析与按时间取行，纯逻辑
final class LyricsTests: XCTestCase {
    func testBasicParse() {
        let lines = Lyrics.parse("[00:12.34]第一句\n[01:02.5]第二句")
        XCTAssertEqual(lines, [LyricLine(time: 12.34, text: "第一句"), LyricLine(time: 62.5, text: "第二句")])
    }

    func testMetadataTagsAreIgnored() {
        let lines = Lyrics.parse("[ti:夜航船]\n[ar:青禾]\n[00:01.00]词")
        XCTAssertEqual(lines, [LyricLine(time: 1, text: "词")])
    }

    func testMultipleStampsOnOneLine() {
        let lines = Lyrics.parse("[00:10.00][00:30.00]副歌")
        XCTAssertEqual(lines.map(\.time), [10, 30])
        XCTAssertTrue(lines.allSatisfy { $0.text == "副歌" })
    }

    func testBlankStampedLineIsKept() {
        // 间奏留白必须保留
        XCTAssertEqual(Lyrics.parse("[00:10.00]"), [LyricLine(time: 10, text: "")])
    }

    func testLineWithoutStampIsDropped() {
        XCTAssertTrue(Lyrics.parse("没有时间戳的一行").isEmpty)
    }

    func testMillisecondAndColonFraction() {
        XCTAssertEqual(Lyrics.parse("[00:01.500]a").first?.time ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(Lyrics.parse("[00:01:50]a").first?.time ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(Lyrics.parse("[00:07]a").first?.time ?? 0, 7, accuracy: 0.0001)
    }

    func testOffsetAppliedAnywhere() {
        // offset:+500 表示歌词整体提前 0.5 秒；写在文件中间也要生效
        let lines = Lyrics.parse("[00:10.00]a\n[offset:+500]\n[00:20.00]b")
        XCTAssertEqual(lines.map(\.time), [9.5, 19.5])
    }

    func testOffsetNeverNegative() {
        XCTAssertEqual(Lyrics.parse("[offset:2000]\n[00:01.00]a").first?.time, 0)
    }

    func testOutOfOrderIsSortedStably() {
        let lines = Lyrics.parse("[00:20.00]后\n[00:05.00]先\n[00:05.00]先二")
        XCTAssertEqual(lines.map(\.text), ["先", "先二", "后"])
    }

    func testCRLF() {
        XCTAssertEqual(Lyrics.parse("[00:01.00]a\r\n[00:02.00]b\r\n").count, 2)
    }

    func testDecodeGB18030() {
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let data = "[00:01.00]你好".data(using: gb)!
        XCTAssertNil(String(data: data, encoding: .utf8))
        XCTAssertEqual(Lyrics.parse(Lyrics.decode(data)).first?.text, "你好")
    }

    func testIndexAtTime() {
        let lines = Lyrics.parse("[00:10.00]a\n[00:20.00]b\n[00:30.00]c")
        XCTAssertNil(Lyrics.index(at: 5, in: lines))
        XCTAssertEqual(Lyrics.index(at: 10, in: lines), 0)
        XCTAssertEqual(Lyrics.index(at: 25, in: lines), 1)
        XCTAssertEqual(Lyrics.index(at: 999, in: lines), 2)
        XCTAssertNil(Lyrics.index(at: 1, in: []))
    }

    func testURLForTrack() {
        let url = URL(fileURLWithPath: "/a/b/夜航船.flac")
        XCTAssertEqual(Lyrics.url(for: url).path, "/a/b/夜航船.lrc")
    }
}
