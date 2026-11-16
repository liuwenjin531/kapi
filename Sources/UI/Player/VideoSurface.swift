import AVKit
import SwiftUI

/// 内嵌画面：只显示视频，控件用播放页自己那套（进度条、上下一首、播放模式）
struct VideoSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        vc.videoGravity = .resizeAspect
        // 圆角做在图层上，而不是在外面套 SwiftUI 的 clipShape：
        // 后者是遮罩，每帧都要多一次离屏合成，帧越大越贵——
        // 6K 素材一帧 1870 万像素，这笔开销很可观。视觉效果两者一致
        vc.view.layer.cornerRadius = 12
        vc.view.layer.cornerCurve = .continuous
        vc.view.layer.masksToBounds = true
        vc.view.backgroundColor = .clear
        // Now Playing 由 PlayerService 自己维护（曲名、封面、队列都在它手上）。
        // 这个属性默认 true，AVKit 会接管并在自己销毁时把信息清空，
        // 于是关掉全屏再进后台，灵动岛就空了
        vc.updatesNowPlayingInfoCenter = false
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}
