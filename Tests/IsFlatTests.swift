import CoreGraphics
import XCTest
@testable import Kapi

/// 校验 `FrameAnalysis.isFlat` 的纯色判定与阈值
final class IsFlatTests: XCTestCase {
    private func make(_ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    private func fill(_ ctx: CGContext, _ r: Double, _ g: Double, _ b: Double, _ rect: CGRect) {
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(rect)
    }

    private let full = CGRect(x: 0, y: 0, width: 64, height: 64)

    func testSolidColorsAreFlat() {
        XCTAssertTrue(FrameAnalysis.isFlat(make { self.fill($0, 1, 1, 1, self.full) }), "纯白应判为纯色帧")
        XCTAssertTrue(FrameAnalysis.isFlat(make { self.fill($0, 0, 0, 0, self.full) }), "纯黑应判为纯色帧")
        XCTAssertTrue(FrameAnalysis.isFlat(make { self.fill($0, 0.2, 0.7, 0.3, self.full) }), "纯绿应判为纯色帧")
    }

    func testWhiteWithLogoIsNotFlat() {
        // 几乎全白但中间有个标志：算有内容，不能误杀
        let image = make {
            self.fill($0, 1, 1, 1, self.full)
            self.fill($0, 0, 0, 0, CGRect(x: 20, y: 20, width: 24, height: 24))
        }
        XCTAssertFalse(FrameAnalysis.isFlat(image))
    }

    func testDimGradientIsNotFlat() {
        // 昏暗但有层次的夜景：算有内容
        let image = make {
            for i in 0..<8 {
                self.fill($0, 0, 0, Double(i) * 0.03, CGRect(x: i * 8, y: 0, width: 8, height: 64))
            }
        }
        XCTAssertFalse(FrameAnalysis.isFlat(image))
    }

    func testImageMagicNumbers() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 16))
        let png = Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 0, count: 16))
        XCTAssertTrue(FrameAnalysis.isImage(jpeg))
        XCTAssertTrue(FrameAnalysis.isImage(png))
        XCTAssertFalse(FrameAnalysis.isImage(Data("[00:01.00]歌词歌词歌词".utf8)))
        XCTAssertFalse(FrameAnalysis.isImage(Data([0xFF, 0xD8])), "太短不当图片")
    }
}
