import SwiftUI

/// 「收到文件」sheet：标题 + 文件名列表 + 「放到」哪个文件夹 + 导入 / 取消。
/// 导入完成后在同一个 sheet 里显示结果，点「完成」收起。
struct ReceiveFilesSheet: View {
    @Environment(ReceivedFiles.self) private var received
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryRoot.self) private var root

    private enum Phase: Equatable {
        case choosing
        case importing
        case done(imported: Int, lyrics: Int, skipped: Int, failed: Int)
    }

    @State private var phase: Phase = .choosing
    @State private var folder = ""
    @State private var pickingFolder = false
    @State private var errorMessage: String?

    private var names: [String] { received.urls.map(\.lastPathComponent) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("收到 \(received.urls.count) 个文件")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.text)

                fileList

                if case .done(let imported, let lyrics, let skipped, let failed) = phase {
                    resultView(imported: imported, lyrics: lyrics, skipped: skipped, failed: failed)
                } else {
                    destinationRow
                }

                Spacer(minLength: 0)

                buttons
            }
            .padding(20)
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationBackground(Theme.bg)
        .presentationDetents([.medium, .large])
        // 导入进行中不能被下滑收起，否则结果没人看、清理也乱
        .interactiveDismissDisabled(phase == .importing)
        .onAppear { folder = Self.restoredFolder(library: library, location: root.location) }
        .sheet(isPresented: $pickingFolder) {
            FolderPicker(title: "放到", verb: "放", startPath: folder) { folder = $0 }
                .environment(library)
                .environment(root)
        }
        .alert("导入失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 子视图

    private var fileList: some View {
        let summary = ReceiveFilesLogic.summarize(names: names)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(summary.shown, id: \.self) { name in
                Label(name, systemImage: "music.note")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.text)
            }
            if summary.more > 0 {
                Text("等 \(summary.more) 个")
                    .foregroundStyle(Theme.secondary)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var destinationRow: some View {
        Button { pickingFolder = true } label: {
            HStack {
                Text("放到")
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Text(ReceiveFilesLogic.folderTitle(folder))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(phase == .importing)
    }

    private func resultView(imported: Int, lyrics: Int, skipped: Int, failed: Int) -> some View {
        var lines: [String] = []
        if imported > 0 {
            lines.append("已导入 \(imported) 首" + (lyrics > 0 ? "，歌词 \(lyrics) 个" : ""))
        } else if lyrics > 0 {
            lines.append("已导入歌词 \(lyrics) 个")
        }
        if skipped > 0 { lines.append("跳过 \(skipped) 个不支持的文件") }
        if failed > 0 { lines.append("\(failed) 个导入失败") }
        if lines.isEmpty { lines.append("没有可导入的文件") }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(.subheadline)
        .foregroundStyle(failed > 0 ? Theme.danger : Theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 10) {
            switch phase {
            case .done:
                capsuleButton("完成", filled: true) { received.dismiss() }
            case .choosing, .importing:
                capsuleButton(phase == .importing ? "正在导入…" : "导入", filled: true) { startImport() }
                    .disabled(phase == .importing)
                capsuleButton("取消", filled: false) { received.dismiss() }
                    .disabled(phase == .importing)
            }
        }
    }

    /// 不用 `.borderedProminent`：它的字固定是白色，深色主题强调色是柠檬绿，白字看不清
    private func capsuleButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(filled ? Theme.onAccent : Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(filled ? Theme.accent : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    private func startImport() {
        guard let files = root.files else { return }
        let urls = received.urls
        let target = folder
        phase = .importing
        UserDefaults.standard.set(target, forKey: ReceiveFilesLogic.lastFolderKey(location: root.location))
        Task {
            do {
                let result = try await files.importFiles(urls, into: target)
                let removable = ReceiveFilesLogic.removable(
                    all: urls, failed: result.failed,
                    systemInbox: ReceivedFiles.systemInbox, shareInbox: ShareInbox.root
                )
                ReceivedFiles.cleanup(removable)
                received.markCompleted()
                let lyrics = result.imported.filter { $0.pathExtension.lowercased() == "lrc" }.count
                phase = .done(
                    imported: result.imported.count - lyrics, lyrics: lyrics,
                    skipped: result.skipped.count, failed: result.failed.count
                )
            } catch {
                // 目标路径非法等整体失败：文件原样留着，回到选择状态让用户改了再试
                errorMessage = error.localizedDescription
                phase = .choosing
            }
        }
    }

    /// 读上次的文件夹；乐库还没读完（节点查不到）时同样退回根目录
    static func restoredFolder(library: LibraryStore, location: LibraryRoot.Location) -> String {
        let saved = UserDefaults.standard.string(forKey: ReceiveFilesLogic.lastFolderKey(location: location))
        return ReceiveFilesLogic.initialFolder(saved: saved) { library.node(at: $0) != nil }
    }
}
