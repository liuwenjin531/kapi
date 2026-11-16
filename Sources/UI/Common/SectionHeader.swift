import SwiftUI

/// 分段小标题「文件夹」「歌曲」
struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview("分段标题") {
    VStack(alignment: .leading, spacing: 0) {
        SectionHeader("文件夹")
        SectionHeader("歌曲")
    }
    .background(Theme.bg)
}
