import SwiftUI

/// 播放相关界面的方形封面：通过环境里的 `artworkProvider` 取图，取不到（没封面、没下载）显示占位色块。
/// 自己是正方形、撑满父级给的宽度，圆角按比例由调用方传
struct PlayerArtwork: View {
    let track: Track
    /// 界面需要的最长边像素，提供方据此缩小
    var maxPixel: CGFloat = 600
    var corner: CGFloat = 20
    /// 占位音符的字号和透明度。默认值给列表、迷你条那些小封面；
    /// 黑胶里的封面大得多，音符要跟着放大并淡一点，不然像个小贴纸
    var symbolSize: CGFloat = 28
    var symbolOpacity: Double = 0.85

    @Environment(\.artworkProvider) private var provider
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Theme.placeholder(for: track.title)
                        Image(systemName: "music.note")
                            .font(.system(size: symbolSize, weight: .regular))
                            .foregroundStyle(.white.opacity(symbolOpacity))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .task(id: track.path) {
                image = nil
                image = await provider.artwork(for: track, maxPixel: maxPixel)
            }
    }
}
