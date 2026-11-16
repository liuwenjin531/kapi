import SwiftUI

/// 多选「加到歌单」：和 `AddToPlaylistSheet` 一样的交互，但一次加一批歌。
/// 单首那个组件不归多选这条线改，所以在这里单独做一份
struct AddTracksToPlaylistSheet: View {
    let tracks: [Track]
    /// 加成功后调用（多选页用来退出多选模式）
    var onAdded: () -> Void = {}

    @Environment(PlaylistStore.self) private var playlists
    @Environment(\.dismiss) private var dismiss

    @State private var showNewAlert = false
    @State private var newName = ""
    @State private var errorMessage: String?

    private var paths: [String] { tracks.map(\.path) }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    newName = ""
                    showNewAlert = true
                } label: {
                    Label("新建歌单", systemImage: "plus")
                }
                .listRowBackground(Theme.card)

                if !playlists.playlists.isEmpty {
                    Section {
                        ForEach(playlists.playlists) { playlist in
                            Button { add(to: playlist) } label: {
                                HStack {
                                    Text(playlist.name)
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    if Set(paths).isSubset(of: playlist.items) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.accent)
                                            .accessibilityLabel("已全部包含")
                                    }
                                }
                            }
                            .listRowBackground(Theme.card)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sheet)
            .navigationTitle("加到歌单")
            .navigationSubtitle("\(tracks.count) 首歌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("新建歌单", isPresented: $showNewAlert) {
                TextField("歌单名称", text: $newName)
                Button("取消", role: .cancel) {}
                Button("创建") { createAndAdd() }
            }
            .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.sheet)
    }

    private func add(to playlist: Playlist) {
        do {
            // add 自己会跳过已在歌单里的
            try playlists.add(paths, to: playlist.id)
            finish()
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func createAndAdd() {
        guard let name = SearchLogic.normalized(newName) else { return }
        do {
            let created = try playlists.create(name: name)
            try playlists.add(paths, to: created.id)
            finish()
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func finish() {
        dismiss()
        onAdded()
    }
}
