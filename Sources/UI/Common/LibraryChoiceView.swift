import SwiftUI

/// 首次启动：选乐库放在哪。
///
/// iCloud 是推荐项、默认选中，保持「基于 iCloud 的播放器」的定位；
/// 本机是兜底，没开 iCloud 的人（包括审核设备）也能马上用起来。以后随时能在设置里切换
struct LibraryChoiceView: View {
    var onChoose: (LibraryRoot.Location) -> Void

    @State private var selection: LibraryRoot.Location = .icloud

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "music.note")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 72, height: 72)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.top, 48)
                        .accessibilityHidden(true)
                    Text("欢迎使用卡皮音乐")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.text)
                    Text("先选乐库放在哪里")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .padding(.bottom, 12)
                    option(.icloud,
                           title: "iCloud 云盘",
                           detail: "多台设备同步，歌单跟着走；没下载的歌点了再下。",
                           recommended: true)
                    option(.local,
                           title: "只存在这台 iPhone",
                           detail: "不需要 iCloud，不同步。用「文件 › 我的 iPhone」、隔空投送或从 App 里导入来加歌。",
                           recommended: false)
                }
                .padding(.horizontal, 24)
            }
            VStack(spacing: 12) {
                Text("以后可以在设置里切换。两边各有一套歌曲和歌单，互不影响。")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.secondary)
                // 不用 borderedProminent：它把字写成白色，深色主题的强调色是柠檬绿，白字看不清
                Button {
                    onChoose(selection)
                } label: {
                    Text("继续")
                        .font(.headline)
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        // 内屏、横放时不把卡片拉得太宽
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func option(_ location: LibraryRoot.Location, title: String, detail: String, recommended: Bool) -> some View {
        let selected = selection == location
        return Button {
            selection = location
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: location.symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    if recommended {
                        Text("推荐")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(selected ? Theme.accent : Theme.secondary.opacity(0.5))
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.separator, lineWidth: selected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview("选择乐库位置") { LibraryChoiceView(onChoose: { _ in }) }
