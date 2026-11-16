import SwiftUI

/// 选目标文件夹：收文件「放到哪」、移动、拷贝共用。
///
/// 从乐库根目录开始一层层往里点；顶部是当前位置，底部按钮把「当前所在的这一层」交给调用方。
/// 右上角能就地新建文件夹（建好后直接进去）。
/// `excluded` 里的文件夹（正在移动的那些，以及它们的子孙）显示成灰色、点不进去：
/// 把文件夹移进它自己里面会出错
struct FolderPicker: View {
    /// 标题，比如「移动 2 项到」「放到」
    let title: String
    /// 确认按钮的动词，按钮写成「\(verb)到「华语」」
    let verb: String
    /// 打开时先停在哪一层（相对路径，根目录为空串）；不存在就退回根目录
    var startPath: String = ""
    /// 不能作为目标的文件夹路径
    var excluded: Set<String> = []
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryRoot.self) private var root

    @State private var path: [String] = []
    @State private var askingName = false
    @State private var newName = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            level("")
                .navigationDestination(for: String.self) { level($0) }
        }
        .presentationBackground(Theme.bg)
        .onAppear { path = Self.stack(to: startPath, in: library) }
        .alert("新建文件夹", isPresented: $askingName) {
            TextField("文件夹名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") { createFolder() }
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var currentPath: String { path.last ?? "" }

    private func level(_ folderPath: String) -> some View {
        let node = library.node(at: folderPath)
        return List {
            if let node {
                ForEach(node.subfolders) { sub in
                    let blocked = Self.isExcluded(sub.path, excluded)
                    NavigationLink(value: sub.path) {
                        Label(sub.name, systemImage: "folder")
                            .foregroundStyle(blocked ? Theme.secondary.opacity(0.5) : Theme.text)
                    }
                    .disabled(blocked)
                    .listRowBackground(Theme.card)
                }
                if node.subfolders.isEmpty {
                    Text("这里没有子文件夹")
                        .foregroundStyle(Theme.secondary)
                        .listRowBackground(Theme.card)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(node?.name ?? "乐库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newName = ""
                    askingName = true
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                Button {
                    onPick(folderPath)
                    dismiss()
                } label: {
                    Text("\(verb)到「\(node?.name ?? "乐库")」")
                        .font(.headline)
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(Self.isExcluded(folderPath, excluded))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.bg)
        }
    }

    private func createFolder() {
        guard let files = root.files else { return }
        let parent = currentPath
        let name = newName
        Task {
            do {
                let created = try await files.createFolder(named: name, in: parent)
                // 扫描结果要等文件系统通知后才更新；先把路径推进去，节点出来前显示为空
                path.append(created)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 某个文件夹是否在排除列表里，或在被排除文件夹的里面
    static func isExcluded(_ folder: String, _ excluded: Set<String>) -> Bool {
        excluded.contains { folder == $0 || folder.hasPrefix($0 + "/") }
    }

    /// 从根目录到 `target` 的逐级路径（不含根目录）；中途有一级不存在就停在那里
    static func stack(to target: String, in library: LibraryStore) -> [String] {
        var stack: [String] = []
        var walked = ""
        for part in target.split(separator: "/") {
            walked = walked.isEmpty ? String(part) : walked + "/" + part
            guard library.node(at: walked) != nil else { break }
            stack.append(walked)
        }
        return stack
    }
}
