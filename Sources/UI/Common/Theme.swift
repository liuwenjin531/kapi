import SwiftUI
import UIKit

/// 深色 / 浅色。存 AppStorage，切换即时生效
enum Skin: String, CaseIterable, Sendable {
    /// case 的顺序就是选择器里的顺序
    case light, dark

    var label: String { self == .dark ? "深色" : "浅色" }
    var scheme: ColorScheme { self == .dark ? .dark : .light }
}

enum Theme {
    /// 浅色 / 深色各一个色值。小组件用到的几个色要同时有「动态色」和「按皮肤直接取」两种读法，
    /// 色值只写这一处，免得两边各抄一份、改一边忘一边
    typealias HexPair = (light: UInt32, dark: UInt32)

    private static let bgHex: HexPair = (0xF6F2EA, 0x0D0F13)
    private static let textHex: HexPair = (0x14161A, 0xF2F3F5)
    private static let secondaryHex: HexPair = (0x7A6E63, 0x7D8291)
    private static let accentHex: HexPair = (0x6F4E37, 0xCDEB5A)
    private static let onAccentHex: HexPair = (0xFFFFFF, 0x2A3208)

    static let bg = dynamic(bgHex)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1E2029)
    static let sheet = dynamic(light: 0xFFFFFF, dark: 0x1A1D24)
    static let text = dynamic(textHex)
    static let secondary = dynamic(secondaryHex)
    static let separator = dynamic(light: 0xE7E0D5, dark: 0x2B2E3A)
    static let danger = dynamic(light: 0xC0392B, dark: 0xE5736B)
    static let warning = dynamic(light: 0xA9670A, dark: 0xE5A03C)
    /// 「删除 N 项」按钮的底色，危险但不刺眼
    static let dangerFill = dynamic(light: 0xFBE8E6, dark: 0x3A1F1E)

    /// 深色下是招牌的柠檬绿；浅色下换成布偶猫的海豹咖。
    /// 这个色 37 处引用里既当填充又当前景，两头都得够：
    /// 白底上当图标 7.2:1，当底色压白字也是 7.2:1
    static let accent = dynamic(accentHex)
    /// accent 当底色时压在上面的字，跟着反过来
    static let onAccent = dynamic(onAccentHex)

    /// 小组件用的固定色板。App 外观是自己的浅色 / 深色开关、不跟随系统，
    /// 小组件得跟着 App 选的皮肤走，而不是跟着系统外观——所以按皮肤直接取色，不走动态色
    struct Palette {
        let bg: Color
        let text: Color
        let secondary: Color
        let accent: Color
        let onAccent: Color
    }

    static func palette(_ skin: Skin) -> Palette {
        func pick(_ pair: HexPair) -> Color { Color(hex: skin == .dark ? pair.dark : pair.light) }
        return Palette(bg: pick(bgHex), text: pick(textHex), secondary: pick(secondaryHex),
                       accent: pick(accentHex), onAccent: pick(onAccentHex))
    }

    /// 无封面时按标题散列取一个占位底色，同一专辑始终同色。
    /// 这几个色是「唱片封面」的替身，两种模式下都压着白色音符，不跟随主题
    static func placeholder(for seed: String) -> Color {
        let palette = [0x4A4470, 0x2F5A52, 0x6B4A2F, 0x3D3A5C, 0x2B3A55, 0x5A2F45]
        var hash: UInt = 5381
        for byte in seed.utf8 { hash = (hash &* 33) &+ UInt(byte) }
        return Color(hex: UInt32(palette[Int(hash % UInt(palette.count))]))
    }

    /// 用动态 UIColor，而不是在每个 view 里读 colorScheme 自己挑：
    /// 一百多处引用一个字都不用改，切换时也不需要谁去手动刷新
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    private static func dynamic(_ pair: HexPair) -> Color {
        dynamic(light: pair.light, dark: pair.dark)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension View {
    /// 图标按钮默认只有图形那么大，几乎点不中。撑到 44×44——HIG 的最小可点区域
    func tappable(_ side: CGFloat = 44) -> some View {
        frame(width: side, height: side).contentShape(.rect)
    }
}

/// mm:ss，超过一小时给 h:mm:ss
func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
