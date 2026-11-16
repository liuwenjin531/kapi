import SwiftUI

/// 自绘进度条（R5：轨道 6pt、白色圆钮 28pt）。
/// 系统 Slider 只认拖动，点轨道不会跳，所以点击和拖动共用一个 DragGesture：
/// 按下和拖动时回报 `onDrag`（界面显示目标时间），松手才 `onCommit` 真正 seek
struct ScrubBar: View {
    let time: TimeInterval
    let total: TimeInterval
    let onDrag: (TimeInterval) -> Void
    let onCommit: (TimeInterval) -> Void

    private let knob: CGFloat = 28
    private let rail: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = min(max(time / max(total, 1), 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.separator).frame(height: rail)
                Capsule().fill(Theme.accent)
                    .frame(width: width * fraction, height: rail)
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .frame(width: knob, height: knob)
                    .offset(x: width * fraction - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onDrag(seconds(at: $0.location.x, width: width)) }
                    .onEnded { onCommit(seconds(at: $0.location.x, width: width)) }
            )
        }
        .frame(height: knob)
        // VoiceOver 原来靠 Slider 自带的「调节」语义，自绘后补回：上滑下滑各跳 5%
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue(formatTime(time))
        .accessibilityAdjustableAction { direction in
            let step = total * 0.05
            switch direction {
            case .increment: onCommit(min(time + step, total))
            case .decrement: onCommit(max(time - step, 0))
            default: break
            }
        }
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> TimeInterval {
        min(max(x / width, 0), 1) * total
    }
}
