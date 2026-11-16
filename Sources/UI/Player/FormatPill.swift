import SwiftUI

/// 格式小胶囊（MP3 / FLAC …）：灰底圆角，大写扩展名
struct FormatPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Theme.separator, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
