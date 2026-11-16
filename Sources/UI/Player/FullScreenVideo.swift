import AVKit
import MediaPlayer
import SwiftUI

/// 全屏播放：交给 AVKit 的默认控件（进度、播放、AirPlay 都是系统的），并放开横屏。
/// 不用 AVPlayerViewController 自带的全屏按钮，是因为内嵌时系统控件关掉了，
/// 那个按钮也就没了；改成自己弹一个全屏页，方向控制权也在自己手上。
/// 在系统控件之上加了一套手势：左半屏上下滑调亮度，右半屏上下滑调音量，左右拖动快进快退（松手才跳）
struct FullScreenVideo: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PlayerService.self) private var player
    @State private var adjust = GestureAdjustModel()
    /// 竖版视频（宽高比 < 1）全屏时不强制转横屏
    let isWide: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            SystemVideoPlayer(player: player.av, playback: player, adjust: adjust)
                .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .tappable()
                    .background(.black.opacity(0.35), in: Circle())
            }
            .padding(.leading, 12)
            .padding(.top, 8)
            .accessibilityLabel("退出全屏")
            AdjustHUD(adjust: adjust)
        }
        .statusBarHidden()
        .onAppear { OrientationGate.set(true, rotateToLandscape: isWide) }
        .onDisappear {
            OrientationGate.set(false)
            // 亮度是系统全局的：在全屏里调暗后，退出时必须还原，否则整台手机都是暗的
            adjust.restoreBrightness()
            // 兜一道：万一还有别的东西动过 Now Playing，关全屏时补写一次
            player.refreshNowPlaying()
        }
        // 进后台也还原；回到前台时若仍在全屏，再套回用户调好的值
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: adjust.restoreBrightness()
            case .active: adjust.reapplyBrightness()
            default: break
            }
        }
    }
}

// MARK: - 手势调节

/// 手势调节的状态：浮层显示什么、亮度怎么还原。
/// 亮度只记「进全屏前的原值」和「用户调出来的值」两个数；音量是系统音量，退出后不还原
@MainActor
@Observable
final class GestureAdjustModel {
    /// 浮层内容。音量没有自己的浮层：改系统音量时系统一定会弹自带的音量条，压不住，
    /// 两个叠着反而乱，所以沿用系统的
    enum HUDContent: Equatable {
        case brightness(CGFloat)
        /// 快进快退：target 是松手后会跳到的位置，delta 是相对起点的偏移
        case seek(target: TimeInterval, delta: TimeInterval, total: TimeInterval)
    }

    /// 当前显示的浮层；nil 表示不显示
    private(set) var hud: HUDContent?

    private var originalBrightness: CGFloat?
    private var adjustedBrightness: CGFloat?
    private var hideTask: Task<Void, Never>?

    func show(_ content: HUDContent) {
        hud = content
        hideTask?.cancel()
    }

    /// 松手后停一会儿再淡出
    func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            hud = nil
        }
    }

    func setBrightness(_ value: CGFloat, on screen: UIScreen) {
        if originalBrightness == nil { originalBrightness = screen.brightness }
        adjustedBrightness = value
        screen.brightness = value
    }

    func restoreBrightness() {
        guard let original = originalBrightness else { return }
        currentScreen?.brightness = original
    }

    func reapplyBrightness() {
        guard let adjusted = adjustedBrightness else { return }
        currentScreen?.brightness = adjusted
    }

    private var currentScreen: UIScreen? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
    }
}

/// 顶部居中的胶囊，只在手势进行时出现，不挡画面中心，也不接收触摸。
/// 亮度：太阳图标 + 进度条 + 百分比；快进快退：方向图标 + 目标时间 / 总时长 + 偏移秒数
private struct AdjustHUD: View {
    let adjust: GestureAdjustModel

    var body: some View {
        ZStack(alignment: .top) {
            if let hud = adjust.hud {
                content(hud)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .frame(width: 270)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(.top, 28)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: adjust.hud == nil)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func content(_ hud: GestureAdjustModel.HUDContent) -> some View {
        switch hud {
        case .brightness(let value):
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule().fill(.white)
                                .frame(width: geo.size.width * value)
                        }
                    }
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .frame(minWidth: 38, alignment: .trailing)
            }
        case .seek(let target, let delta, let total):
            HStack(spacing: 10) {
                Image(systemName: delta < 0 ? "backward.fill" : "forward.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                Text("\(clock(target)) / \(clock(total))")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                Spacer(minLength: 0)
                Text(signed(delta))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
        }
    }

    /// 1:32 或 1:02:03（满一小时才带小时）
    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// +12s / −8s；超过一分钟写成 +1:05
    private func signed(_ d: TimeInterval) -> String {
        let n = Int(abs(d).rounded())
        let sign = d < 0 ? "\u{2212}" : "+"
        return n < 60 ? "\(sign)\(n)s" : "\(sign)\(clock(TimeInterval(n)))"
    }
}

private struct SystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    /// 快进快退要走 PlayerService.seek：进度条、灵动岛和控制中心的时间才会一起更新
    let playback: PlayerService
    let adjust: GestureAdjustModel

    func makeCoordinator() -> Coordinator { Coordinator(adjust: adjust, playback: playback) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        // 同 VideoSurface：不让 AVKit 碰 Now Playing，否则全屏关闭时会连带清掉
        vc.updatesNowPlayingInfoCenter = false
        context.coordinator.install(on: vc.view)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }

    /// 手势挂在播放器的 view 上，而不是在视频上盖一层透明视图：
    /// 盖层会吃掉点击，系统控件「点一下显示/隐藏」就失效了。
    /// 起手时按滑动方向定模式，之后整段手势不再换：竖向调亮度/音量，横向快进快退
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        enum Mode { case brightness, volume, seek }

        /// 上下边缘留白（占高度的比例）：顶部是控制中心下拉，底部是系统进度条和回主屏上滑。
        /// 起点落在里面不触发。数值是提议值，真机上再调
        private let topGuard: CGFloat = 0.11
        private let bottomGuard: CGFloat = 0.19
        /// 横向快进快退另外避开左右边缘这么多 pt，免得和系统边缘手势抢
        private let edgeGuard: CGFloat = 20
        /// 横向速度要明显大于竖向才算横向；斜着划时竖向略占优先，减少误触快进
        private let horizontalBias: CGFloat = 1.25
        /// 竖向：手指滑过画面高度的这一比例，对应 0%→100%
        private let travel: CGFloat = 0.5
        /// 横向：滑过整个屏幕宽度对应的秒数 = 视频时长的 25%，限制在 60 秒到 10 分钟。
        /// 按比例算是因为 3~5 分钟的 MV 和几小时的演唱会全场差几十倍
        private let seekSpanRatio: TimeInterval = 0.25
        private let seekSpanRange: ClosedRange<TimeInterval> = 60...600

        private let adjust: GestureAdjustModel
        private let playback: PlayerService
        /// 系统没有公开的「设置音量」接口，业界通用做法是操作 MPVolumeView 里的 UISlider。
        /// 放在屏幕外，只借它的滑块改音量。系统自带的音量条会照常弹出，我们不压它也不另画
        private let volumeView = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 1, height: 1))

        private var mode: Mode = .brightness
        private var pendingMode: Mode?
        private var startValue: CGFloat = 0
        /// 快进快退：起点位置和当前拖到的目标位置。拖动中只更新浮层，松手才真正 seek——
        /// 6K 素材每次 seek 都要重新解码，连续跳会卡
        private var seekStart: TimeInterval = 0
        private var seekTarget: TimeInterval = 0

        init(adjust: GestureAdjustModel, playback: PlayerService) {
            self.adjust = adjust
            self.playback = playback
        }

        func install(on view: UIView) {
            view.addSubview(volumeView)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            view.addGestureRecognizer(pan)
        }

        func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
            guard let pan = gr as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let w = view.bounds.width, h = view.bounds.height
            guard w > 0, h > 0 else { return false }
            // 手势识别出来时手指已经动了一小段，从当前位置倒推落下的起点
            let t = pan.translation(in: view)
            let p = pan.location(in: view)
            let start = CGPoint(x: p.x - t.x, y: p.y - t.y)
            guard start.y > h * topGuard, start.y < h * (1 - bottomGuard) else { return false }

            let v = pan.velocity(in: view)
            if abs(v.x) > abs(v.y) * horizontalBias {
                // 横向：快进快退。时长未知（还没读到）时没法算，不触发
                guard start.x > edgeGuard, start.x < w - edgeGuard,
                      playback.duration.isFinite, playback.duration > 0 else { return false }
                pendingMode = .seek
                return true
            }
            guard abs(v.y) > abs(v.x) else { return false }
            pendingMode = start.x < w / 2 ? .brightness : .volume
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            switch pan.state {
            case .began:
                mode = pendingMode ?? .brightness
                switch mode {
                case .seek:
                    seekStart = playback.currentTime
                    seekTarget = seekStart
                    adjust.show(.seek(target: seekStart, delta: 0, total: playback.duration))
                case .brightness, .volume:
                    startValue = currentValue(mode, view: view)
                    if mode == .brightness { adjust.show(.brightness(startValue)) }
                }
            case .changed:
                switch mode {
                case .seek:
                    let total = playback.duration
                    let span = min(max(total * seekSpanRatio, seekSpanRange.lowerBound), seekSpanRange.upperBound)
                    let delta = TimeInterval(pan.translation(in: view).x / view.bounds.width) * span
                    seekTarget = min(max(seekStart + delta, 0), total)
                    adjust.show(.seek(target: seekTarget, delta: seekTarget - seekStart, total: total))
                case .brightness, .volume:
                    // 相对起点算增量：向上为增。不是点到哪就跳到哪
                    let delta = -pan.translation(in: view).y / (view.bounds.height * travel)
                    let value = min(max(startValue + delta, 0), 1)
                    apply(value, mode: mode, view: view)
                    if mode == .brightness { adjust.show(.brightness(value)) }
                }
            case .ended:
                // 松手才跳；几乎没动（不到 1 秒）就不跳，免得白白触发一次解码
                if mode == .seek, abs(seekTarget - seekStart) >= 1 { playback.seek(to: seekTarget) }
                adjust.scheduleHide()
            case .cancelled, .failed:
                adjust.scheduleHide()
            default: break
            }
        }

        private func currentValue(_ mode: Mode, view: UIView) -> CGFloat {
            switch mode {
            case .brightness: view.window?.windowScene?.screen.brightness ?? 0.5
            case .volume: CGFloat(AVAudioSession.sharedInstance().outputVolume)
            case .seek: 0
            }
        }

        private func apply(_ value: CGFloat, mode: Mode, view: UIView) {
            switch mode {
            case .brightness:
                if let screen = view.window?.windowScene?.screen { adjust.setBrightness(value, on: screen) }
            case .volume:
                let slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
                slider?.value = Float(value)
            case .seek:
                break
            }
        }
    }
}
