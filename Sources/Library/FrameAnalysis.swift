import CoreGraphics
import Foundation

/// 图像分析的纯函数，只依赖 CoreGraphics，可以脱离 UIKit 单测。
enum FrameAnalysis {
    /// 这帧是不是几乎纯色（黑场、白场、纯色片头都算）。
    /// 缩到 8×8 后看亮度的标准差：纯色帧每块都一样，差值趋近 0；
    /// 有内容的帧总有明暗分布。比「平均值是不是接近 0」通用——
    /// 后者只挡得住黑场，白场和纯色卡的平均亮度是正常的
    static func isFlat(_ image: CGImage) -> Bool {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }   // 读不出来就当它有内容，宁可留张图也别丢空
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        // 拆成显式循环而不是 map/reduce 链：混着字面量和 Double(UInt8) 的表达式
        // 会把 Swift 的类型检查器卡死（编译报 unable to type-check in reasonable time）
        var luma = [Double]()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
            luma.append(0.299 * r + 0.587 * g + 0.114 * b)
        }
        let count = Double(luma.count)
        var sum = 0.0
        for value in luma { sum += value }
        let mean = sum / count
        var squares = 0.0
        for value in luma {
            let d = value - mean
            squares += d * d
        }
        let variance = squares / count
        // 阈值按 0~255 的标准差算：3 以下肉眼已经看不出层次
        return variance.squareRoot() < 3
    }

    /// 认 JPEG / PNG / GIF / WebP 的魔数，别把歌词之类的二进制当成图
    static func isImage(_ data: Data) -> Bool {
        guard data.count > 12 else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }                     // JPEG
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }       // PNG
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return true }                     // GIF
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }     // WebP
        return false
    }
}
