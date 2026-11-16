import SwiftUI

/// 选一个歌单把歌加进去。已包含这首的歌单右侧打勾；顶部「新建歌单」，建好立即加入。
struct AddToPlaylistSheet: View {
    let track: Track

    @Environment(PlaylistStore.self) private var playlists
    @Environment(\.dismiss) private var dismiss

    @State private var showNewAlert = false
    @State private var newName = ""
    @State private var errorMessage: String?

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
                            Button {
                                add(to: playlist)
                            } label: {
                                HStack {
                                    Text(playlist.name)
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    if playlist.items.contains(track.path) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.accent)
                                            .accessibilityLabel("已包含")
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
            .alert("操作失败", isPresented: errorBinding) {
                Button("好") {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        // 系统 sheet 默认白底，List 的背景只盖住列表区，要整张 sheet 都跟主题走
        .presentationBackground(Theme.sheet)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func add(to playlist: Playlist) {
        // 已经在里面：什么都不改，直接收起，不要报错
        if playlist.items.contains(track.path) {
            dismiss()
            return
        }
        do {
            try playlists.add([track.path], to: playlist.id)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func createAndAdd() {
        guard let name = SearchLogic.normalized(newName) else { return }
        do {
            let created = try playlists.create(name: name)
            try playlists.add([track.path], to: created.id)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }
}
