import SwiftUI

/// 播放页的黑胶唱片：圆底 + 描边圈 + 圆形封面 + 中心孔，整体按 `angle` 旋转。
/// 尺寸由父级给的宽度决定（自己是正方形），各部分按 280pt 版式等比缩放，
/// 这样手机、外屏、内屏横放的小封面档位都不用另写一套
struct VinylDisc: View {
    let track: Track
    /// 当前转角（度），由播放页根据播放进度算
    var angle: Double
    /// 封面解码的最长边像素
    var maxPixel: CGFloat = 900

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let d = geo.size.width
                    // 版式按 280pt：描边 8、描边圈内缩 6、封面 210、中心孔 20
                    let unit = d / 280
                    ZStack {
                        Circle().fill(Theme.card)
                        Circle().stroke(Theme.separator, lineWidth: 8 * unit).padding(6 * unit)
                        // 圆角给整个直径，RoundedRectangle 会自己夹成半宽，也就是正圆
                        PlayerArtwork(
                            track: track, maxPixel: maxPixel, corner: d,
                            symbolSize: 210 * unit * 0.34, symbolOpacity: 0.55
                        )
                        .frame(width: 210 * unit, height: 210 * unit)
                        Circle().fill(Theme.bg).frame(width: 20 * unit, height: 20 * unit)
                    }
                    .frame(width: d, height: d)
                }
            }
            .rotationEffect(.degrees(angle))
    }
}
