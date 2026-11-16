import SwiftUI

/// 设置（sheet）：乐库位置（本机 / iCloud 切换）、外观、关于。
/// 睡眠定时不在这里，在播放页「⋯」里
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryRoot.self) private var libraryRoot
    /// 外观只有浅色 / 深色，没有「跟随系统」；App 层读同一个键
    @AppStorage("skin") private var skin: Skin = .light

    /// 隐私政策页面，托管在开源仓库里。App Store Connect 的「隐私政策网址」要填同一个地址，改的话两处一起改
    private static let privacyURL = URL(string: "https://github.com/liuwenjin531/kapi/blob/main/PRIVACY.md")

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)（\(build)）"
    }

    private var isLocal: Bool { libraryRoot.location == .local }
    /// 用户点了另一边、还没确认的位置；确认框靠它弹出
    @State private var pendingLocation: LibraryRoot.Location?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // 两个位置是两套独立的乐库：分段控件只表达「读哪一边」，改动要先确认（会停掉正在播放的）
                    Picker("乐库位置", selection: Binding(
                        get: { libraryRoot.location },
                        set: { if $0 != libraryRoot.location { pendingLocation = $0 } }
                    )) {
                        ForEach(LibraryRoot.Location.allCases, id: \.self) { location in
                            Label(location.title, systemImage: location.symbol).tag(location)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Theme.card)
                    HStack(spacing: 12) {
                        Image(systemName: isLocal ? "iphone" : "icloud")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isLocal ? "本机 · 卡皮音乐" : "iCloud 云盘 · 卡皮音乐")
                                .foregroundStyle(Theme.text)
                        }
                        Spacer(minLength: 8)
                        if !isLocal {
                            Text("已连接")
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .listRowBackground(Theme.card)
                } header: {
                    Text("乐库位置")
                } footer: {
                    Text((isLocal
                         ? "乐库是本机上的「卡皮音乐」文件夹，在「文件」App 的「我的 iPhone」里也能看到，不同步到其他设备。"
                         : "乐库是 iCloud 云盘里的「卡皮音乐」文件夹，多台设备同步。")
                         + "本机和 iCloud 各有一套歌曲和歌单，互不影响；切换只是换一个文件夹来读。")
                }
                .alert(
                    pendingLocation.map { "切换到\($0.title)乐库？" } ?? "",
                    isPresented: Binding(get: { pendingLocation != nil }, set: { if !$0 { pendingLocation = nil } }),
                    presenting: pendingLocation
                ) { target in
                    Button("取消", role: .cancel) {}
                    Button("切换") { libraryRoot.choose(target) }
                } message: { _ in
                    Text("正在播放的会停止。\(libraryRoot.location.title)里的歌和歌单都还在，切回来就能看到。")
                }

                Section("外观") {
                    Picker("外观", selection: $skin) {
                        ForEach(Skin.allCases, id: \.self) { skin in
                            Text(skin.label).tag(skin)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Theme.card)
                }

                Section("关于") {
                    LabeledContent("版本", value: version)
                        .listRowBackground(Theme.card)
                    if let url = Self.privacyURL {
                        Link(destination: url) {
                            HStack {
                                Text("隐私政策")
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                        .listRowBackground(Theme.card)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sheet)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview("设置") {
    Color.clear.sheet(isPresented: .constant(true)) { SettingsView().environment(LibraryRoot()) }
}
