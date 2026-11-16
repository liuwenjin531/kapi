import SwiftUI

/// 「⋯ › 调整歌词时间」：整首歌的歌词整体提前或延后。
/// 做成矮 sheet 并且背后可交互：调的时候要一边听一边看上面的歌词跟不跟得上，整页盖住就没法调了
struct LyricTimingSheet: View {
    @Environment(LyricOffsetStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let track: Track
    @State private var notice: String?

    private var milliseconds: Int { store.offsetMs(for: track.path) }

    var body: some View {
        VStack(spacing: 16) {
            Text("调整歌词时间")
                .font(.headline)
                .foregroundStyle(Theme.text)
            Text(status)
                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                .foregroundStyle(milliseconds == 0 ? Theme.secondary : Theme.accent)
            Text("歌词比人声晚就点「提前」，比人声早就点「延后」")
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                step("提前", "0.5 秒", by: 500)
                step("提前", "0.1 秒", by: 100)
                step("延后", "0.1 秒", by: -100)
                step("延后", "0.5 秒", by: -500)
            }
            HStack {
                Button(role: .destructive) { apply(0) } label: {
                    Label("恢复原样", systemImage: "arrow.counterclockwise")
                }
                .disabled(milliseconds == 0)
                Spacer()
                Button("完成") { dismiss() }
                    .fontWeight(.semibold)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sheet.ignoresSafeArea())
        .presentationDetents([.height(290)])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled)
        .alert("提示", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private var status: String {
        guard milliseconds != 0 else { return "与歌词文件一致" }
        let seconds = String(format: "%.1f 秒", Double(abs(milliseconds)) / 1000)
        return (milliseconds > 0 ? "提前 " : "延后 ") + seconds
    }

    /// 方向在上、数值在下固定两行：一行写「提前 0.5 秒」在窄屏上放不下，会把「秒」挤到下一行
    private func step(_ direction: String, _ amount: String, by delta: Int) -> some View {
        Button { apply(milliseconds + delta) } label: {
            VStack(spacing: 2) {
                Text(direction).font(.system(size: 14, weight: .semibold))
                Text(amount).font(.system(size: 12).monospacedDigit())
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel("\(direction) \(amount)")
        .buttonStyle(.bordered)
        .tint(Theme.accent)
    }

    private func apply(_ value: Int) {
        do {
            try store.setOffset(value, for: track)
        } catch {
            switch error {
            case .stillSyncing: notice = "还在同步，稍后再试"
            case .readOnly: notice = "歌词时间文件来自更新版本的卡皮音乐，现在只能查看，不能修改"
            default: notice = "暂时无法保存，稍后再试"
            }
        }
    }
}
