import SwiftUI

/// 页面该用哪种排法。
///
/// - `compact`：iPhone、iPhone Duo 外屏。单栏，一行一个。
/// - `wideLandscape`：Duo 内屏横放。详情页、文件夹页、搜索、播放页左右拆；歌单页两列；迷你条换成完整播放条。
/// - `widePortrait`：Duo 内屏竖着拿。栏回到上下横向，内容多放一列，但不左右拆。
///
/// 只看「水平 size class + 可用区域的宽高比」，不认机型、不写死屏幕尺寸：
/// HIG 要求 Duo 靠 size class 和安全区自适应，以后别的大屏设备也能直接用上
enum AdaptiveLayout: Equatable, Sendable {
    case compact
    case wideLandscape
    case widePortrait

    var isWide: Bool { self != .compact }

    /// 由 RootView 按整个 App 可用区域算一次，往下注入
    static func resolve(sizeClass: UserInterfaceSizeClass?, size: CGSize) -> AdaptiveLayout {
        // 有的环境（预览、外屏刚展开的一瞬）size class 还没给，用宽度兜底：
        // 600pt 以下一定是手机竖屏级别的宽度，单栏
        let regular = sizeClass == .regular || (sizeClass == nil && size.width >= 600)
        guard regular, size.width > 0 else { return .compact }
        return size.width > size.height ? .wideLandscape : .widePortrait
    }
}

extension EnvironmentValues {
    /// 默认 compact：预览、sheet 里没注入时按手机排
    @Entry var adaptiveLayout: AdaptiveLayout = .compact
}

extension View {
    /// 挂在 App 最外层：量出可用区域，算出排法注入环境。
    /// 用 onGeometryChange 而不是 GeometryReader 包一层，免得改变子视图的布局行为
    func resolvesAdaptiveLayout() -> some View {
        modifier(AdaptiveLayoutResolver())
    }
}

private struct AdaptiveLayoutResolver: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .environment(\.adaptiveLayout, AdaptiveLayout.resolve(sizeClass: sizeClass, size: size))
    }
}

/// 内屏横放时的「左右拆」页面骨架：
/// 左边窄、固定不滚（标题、统计、按钮、筛选），右边宽、单独滚动（列表）。
///
/// 左栏宽度按比例给（约 36%），并夹在一个区间里：太窄放不下「随机 / 播放」，太宽右边列表就挤了。
/// HIG：完全展平时左窄右宽；半折时系统让左右等宽、分界落在折痕上——那时由调用方换成等宽，
/// 这里先只做展平的情况（模拟器不报折痕区域，半折要真机验）
struct SplitPage<Leading: View, Trailing: View>: View {
    /// 左栏占总宽的比例
    var leadingFraction: CGFloat = 0.36
    var leadingRange: ClosedRange<CGFloat> = 260...380
    /// 左栏内容在纵向上的对齐：详情页、文件夹页顶对齐；播放页居中
    var leadingAlignment: Alignment = .top
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        GeometryReader { proxy in
            let width = min(max(proxy.size.width * leadingFraction, leadingRange.lowerBound), leadingRange.upperBound)
            HStack(alignment: .top, spacing: 0) {
                // 左栏内容比屏高时仍能滚（比如字号调大），平时不动
                ScrollView {
                    leading()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: leadingAlignment)

                trailing()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
