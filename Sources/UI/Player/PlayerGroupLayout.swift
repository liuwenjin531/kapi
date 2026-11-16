import SwiftUI

/// 播放页「封面 / 视频 + 其余控制」这一组的排法：两个子视图，第一个是画面，第二个是标题到底排。
///
/// 为什么不用 VStack + Spacer：画面是「按比例缩进剩余空间」的视图，在 VStack 里会吃光所有富余高度，
/// 标题被挤到屏幕底、画面和标题之间空一大块（外屏看 MV 就是这样）。
/// 这里先量出下半部分要多高，剩下的高度才给画面（画面自己按比例取不超过的最大尺寸），
/// 再把整组在纵向上居中——空间富余时整组居中，空间紧时画面缩小，下半部分不动
struct PlayerGroupLayout: Layout {
    /// 画面和下半部分之间的间距
    var spacing: CGFloat = 0

    private func measure(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (media: CGSize, info: CGSize) {
        let width = proposal.width ?? 320
        let info = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let remaining = proposal.height.map { max(0, $0 - info.height - spacing) }
        let media = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: remaining))
        return (media, info)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let m = measure(proposal, subviews)
        // 高度向父级「要满」：这样整组是在整页高度里居中，而不是贴着顶
        return CGSize(width: proposal.width ?? m.media.width, height: proposal.height ?? (m.media.height + spacing + m.info.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let m = measure(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        let group = m.media.height + spacing + m.info.height
        let top = bounds.minY + max(0, (bounds.height - group) / 2)
        subviews[0].place(
            at: CGPoint(x: bounds.midX, y: top),
            anchor: .top,
            proposal: ProposedViewSize(m.media)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: top + m.media.height + spacing),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: m.info.height)
        )
    }
}
