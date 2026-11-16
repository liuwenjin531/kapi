import SwiftUI
import Observation

/// 一次整理操作的对象：一批歌 + 一批文件夹。单项操作就是只有一项的批量。
struct OrganizeTarget: Identifiable {
    let id = UUID()
    var songs: [Track] = []
    var folders: [FolderNode] = []

    init(songs: [Track] = [], folders: [FolderNode] = []) {
        self.songs = songs
        self.folders = folders
    }

    var count: Int { songs.count + folders.count }
    var isEmpty: Bool { count == 0 }
    /// 文件夹里（递归）的歌数
    var songsInFolders: Int { folders.reduce(0) { $0 + $1.trackCount } }

    /// 受影响的所有歌：直接选的 + 文件夹里的（递归），按路径去重。
    /// 「加到歌单」「从播放队列摘掉」都按这个算
    var allSongs: [Track] {
        var seen = Set<String>()
        return (songs + folders.flatMap(\.allTracks)).filter { seen.insert($0.path).inserted }
    }

    /// 打开「选目标文件夹」时先停在哪：第一项所在的文件夹
    var startPath: String {
        if let song = songs.first { return song.folderPath }
        if let folder = folders.first { return (folder.path as NSString).deletingLastPathComponent }
        return ""
    }

    /// 单项时的名字，批量时是「N 项」
    var summary: String {
        if count == 1 { return "「\(songs.first?.title ?? folders.first?.name ?? "")」" }
        return "\(count) 项"
    }
}

/// 整理操作的界面状态：哪个弹窗开着、针对什么。
/// 放在一个对象里，是因为长按菜单和多选工具条触发的是同一套弹窗（`OrganizeDialogs`）
@Observable
@MainActor
final class OrganizeModel {
    enum Kind { case move, copy

        var verb: String { self == .move ? "移动" : "拷贝" }
    }

    struct Picking: Identifiable {
        let id = UUID()
        let target: OrganizeTarget
        let kind: Kind
    }

    struct Notice: Equatable {
        var title: String
        var message: String
    }

    /// 「加到歌单」的曲目批，给 `sheet(item:)` 一个身份
    struct TrackBatch: Identifiable {
        let id = UUID()
        let tracks: [Track]
    }

    var renaming: OrganizeTarget?
    var renameText = ""
    var picking: Picking?
    var deleting: OrganizeTarget?
    var addingToPlaylist: TrackBatch?
    var notice: Notice?

    /// 操作成功（哪怕只成功一部分）之后调用：多选页用它退出多选模式
    var onFinished: (() -> Void)?

    func askRename(_ target: OrganizeTarget) {
        if let song = target.songs.first {
            // 只编辑文件名主体，扩展名由系统保留，用户改不到
            renameText = (song.fileName as NSString).deletingPathExtension
        } else if let folder = target.folders.first {
            renameText = folder.name
        }
        renaming = target
    }

    func askMove(_ target: OrganizeTarget) { picking = Picking(target: target, kind: .move) }
    func askCopy(_ target: OrganizeTarget) { picking = Picking(target: target, kind: .copy) }
    func askDelete(_ target: OrganizeTarget) { deleting = target }
    func askAddToPlaylist(_ target: OrganizeTarget) {
        let tracks = target.allSongs
        guard !tracks.isEmpty else { return }
        addingToPlaylist = TrackBatch(tracks: tracks)
    }
}

/// 长按菜单里的整理项：重命名、移动到…、拷贝到…、选择。
/// `onSelect` 为 nil（搜索页、歌单详情里没有多选）就不显示「选择」
struct OrganizeMenuItems: View {
    let model: OrganizeModel
    let target: OrganizeTarget
    var onSelect: (() -> Void)?

    var body: some View {
        Button { model.askRename(target) } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button { model.askMove(target) } label: {
            Label("移动到…", systemImage: "folder")
        }
        Button { model.askCopy(target) } label: {
            Label("拷贝到…", systemImage: "doc.on.doc")
        }
        if let onSelect {
            Button { onSelect() } label: {
                Label("选择", systemImage: "checkmark.circle")
            }
        }
    }
}

/// 挂上整理操作的全部弹窗：重命名输入框、选目标文件夹、删除确认、加到歌单、结果提示，
/// 并在这里把文件操作、歌单、歌词微调、播放队列串起来。
///
/// 环境里需要 `LibraryRoot`、`PlaylistStore`、`LyricOffsetStore`、`PlayerService`、`LibraryStore`（FolderPicker 用）。
struct OrganizeDialogs: ViewModifier {
    @Bindable var model: OrganizeModel

    @Environment(LibraryRoot.self) private var root
    @Environment(PlaylistStore.self) private var playlists
    @Environment(LyricOffsetStore.self) private var lyricOffsets
    @Environment(PlayerService.self) private var player

    func body(content: Content) -> some View {
        content
            .alert("重命名", isPresented: flag(\.renaming), presenting: model.renaming) { target in
                TextField("名称", text: $model.renameText)
                Button("取消", role: .cancel) {}
                Button("好") { rename(target, to: model.renameText) }
            } message: { target in
                if target.songs.isEmpty {
                    Text("文件夹里的内容不受影响。")
                } else {
                    Text("只改文件名，扩展名保持不变；同名歌词会一起改。")
                }
            }
            .sheet(item: $model.picking) { picking in
                FolderPicker(
                    title: "\(picking.kind.verb)\(picking.target.summary)到",
                    verb: picking.kind.verb,
                    startPath: picking.target.startPath,
                    // 文件夹及其子孙不能作为自己的目标
                    excluded: Set(picking.target.folders.map(\.path))
                ) { destination in
                    transfer(picking.target, to: destination, kind: picking.kind)
                }
            }
            .confirmationDialog(
                deleteTitle(model.deleting), isPresented: flag(\.deleting),
                titleVisibility: .visible, presenting: model.deleting
            ) { target in
                Button("删除", role: .destructive) { delete(target) }
            } message: { target in
                Text(deleteMessage(target))
            }
            .sheet(item: $model.addingToPlaylist) { batch in
                AddTracksToPlaylistSheet(tracks: batch.tracks) { model.onFinished?() }
            }
            .alert(model.notice?.title ?? "", isPresented: noticeBinding) {
                Button("好") {}
            } message: {
                Text(model.notice?.message ?? "")
            }
    }

    private func flag<T>(_ keyPath: ReferenceWritableKeyPath<OrganizeModel, T?>) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] != nil }, set: { if !$0 { model[keyPath: keyPath] = nil } })
    }

    private var noticeBinding: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    // MARK: 删除确认文案

    private func deleteTitle(_ target: OrganizeTarget?) -> String {
        guard let target else { return "" }
        if target.count == 1, let folder = target.folders.first { return "删除文件夹「\(folder.name)」？" }
        if target.count == 1, let song = target.songs.first { return "删除「\(song.title)」？" }
        return "删除 \(target.count) 项？"
    }

    /// 写明文件夹里有多少首歌会一起删，并补一句 iCloud 同步（本机模式 `deletionSyncNote` 为空）
    private func deleteMessage(_ target: OrganizeTarget) -> String {
        var parts: [String] = []
        if target.folders.isEmpty {
            parts.append("这些歌会被删除，不能恢复。")
        } else if target.count == 1 {
            parts.append("里面 \(target.songsInFolders) 首歌会一起删除，不能恢复。")
        } else {
            var detail = "\(target.folders.count) 个文件夹"
            if !target.songs.isEmpty { detail = "\(target.songs.count) 首歌和" + detail }
            parts.append("将删除\(detail)，文件夹里共 \(target.songsInFolders) 首歌会一起删除，不能恢复。")
        }
        let note = LibraryRoot.Location.stored.deletionSyncNote
        if !note.isEmpty { parts.append(note) }
        return parts.joined()
    }

    // MARK: 执行

    private func rename(_ target: OrganizeTarget, to text: String) {
        guard let files = root.files else {
            model.notice = .init(title: "无法重命名", message: PlaylistError.notAttached.userMessage)
            return
        }
        Task {
            do {
                let result: OrganizeResult
                if let song = target.songs.first {
                    result = try await files.renameSong(song, to: text)
                } else if let folder = target.folders.first {
                    result = try await files.renameFolder(folder.path, to: text)
                } else {
                    return
                }
                finish(result, title: "重命名")
            } catch {
                model.notice = .init(title: "无法重命名", message: error.localizedDescription)
            }
        }
    }

    private func transfer(_ target: OrganizeTarget, to destination: String, kind: OrganizeModel.Kind) {
        guard let files = root.files else {
            model.notice = .init(title: "无法\(kind.verb)", message: PlaylistError.notAttached.userMessage)
            return
        }
        let songs = target.songs
        let folders = target.folders.map(\.path)
        Task {
            do {
                let result = kind == .move
                    ? try await files.move(songs: songs, folders: folders, to: destination)
                    : try await files.copy(songs: songs, folders: folders, to: destination)
                finish(result, title: kind.verb)
            } catch {
                model.notice = .init(title: "无法\(kind.verb)", message: error.localizedDescription)
            }
        }
    }

    private func delete(_ target: OrganizeTarget) {
        guard let files = root.files else {
            model.notice = .init(title: "删除失败", message: PlaylistError.notAttached.userMessage)
            return
        }
        // 先把里面的歌从播放队列摘掉（正在播的会停）：文件删掉后继续读会报错。
        // 多选时某项删失败的话，这些歌也已被摘掉——和单首删除同一个取舍
        player.evict(paths: Set(target.allSongs.map(\.path)))
        let songs = target.songs
        let folders = target.folders.map(\.path)
        Task {
            let result = await files.delete(songs: songs, folders: folders)
            finish(result, title: "删除")
        }
    }

    /// 操作做完：路径变化同步给歌单 / 最爱 / 歌词微调 / 播放队列；有失败或没能同步的，弹一个提示
    private func finish(_ result: OrganizeResult, title: String) {
        var lines = result.failures
        if !result.changes.isEmpty { lines += follow(result.changes) }
        if result.succeeded > 0 || result.skipped > 0 { model.onFinished?() }
        guard !lines.isEmpty else { return }
        model.notice = .init(title: result.succeeded == 0 ? "\(title)失败" : "\(title)未全部完成",
                             message: lines.joined(separator: "\n"))
    }

    /// 文件已经改了；歌单等是跟着改。哪个没改成就如实告诉用户，不吞
    private func follow(_ changes: [PathChange]) -> [String] {
        var notes: [String] = []
        do {
            try playlists.applyMoves(changes)
        } catch {
            notes.append("歌单和最爱里的路径没能更新：\(error.userMessage)")
        }
        do {
            try lyricOffsets.applyMoves(changes)
        } catch {
            notes.append("歌词时间微调没能更新：\(error.userMessage)")
        }
        if let docs = root.documentsURL { player.follow(changes, documentsURL: docs) }
        return notes
    }
}

extension View {
    func organizeDialogs(_ model: OrganizeModel) -> some View {
        modifier(OrganizeDialogs(model: model))
    }
}
