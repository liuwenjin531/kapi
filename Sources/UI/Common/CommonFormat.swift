import Foundation

/// 列表和方格里显示的数字文字。统一在这里格式化，免得各组件拼出不一样的写法。
enum CommonFormat {
    /// 体积：≥1 GB 两位小数（1.20 GB），≥1 MB 一位小数（9.2 MB），更小的交给 ByteCountFormatter（如 512 KB）。
    /// 小数位数是固定的，ByteCountFormatter 本身控制不了小数位，所以大单位手动格式化。
    static func fileSize(_ bytes: Int64) -> String {
        let gib: Double = 1_073_741_824
        let mib: Double = 1_048_576
        let value = Double(bytes)
        if value >= gib { return String(format: "%.2f GB", value / gib) }
        if value >= mib { return String(format: "%.1f MB", value / mib) }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 「38 首 · 1.20 GB」，歌单行和文件夹行共用
    static func countAndSize(count: Int, bytes: Int64) -> String {
        "\(count) 首 · \(fileSize(bytes))"
    }
}
