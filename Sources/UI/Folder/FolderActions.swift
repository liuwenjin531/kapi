import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Observation

/// 相册里选中的视频，落成临时文件后再交给 `importFiles`。
///
/// 用 `PhotosPicker`（系统进程选择）而不是自己读相册，所以**不需要相册权限**。
/// 必须 `FileRepresentation` 落盘：视频动辄几百 MB，用 `Data` 会整个读进内存。
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            // 系统给的 received.file 在这个闭包返回后就会被清掉，必须在这里拷走。
            // 每次用独立的子目录，避免两个同名视频（IMG_0001.MOV）互相覆盖
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "kapi-photo-import-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedVideo(url: copy)
        }
    }
}

/// 导入完成后的文字提示。纯逻辑，单测用
enum ImportSummary {
    /// 「已导入 3 首，跳过 1 个（不是音频或视频），失败 1 个」。
    /// `imported` 里可能含跟着歌一起拷进去的 .lrc，只数歌，歌词不算「首」
    static func message(imported: Int, skipped: Int, failed: Int) -> String {
        var parts: [String] = []
        if imported > 0 || (skipped == 0 && failed == 0) { parts.append("已导入 \(imported) 首") }
        if skipped > 0 { parts.append("跳过 \(skipped) 个（不是音频或视频）") }
        if failed > 0 { parts.append("失败 \(failed) 个") }
        return parts.joined(separator: "，")
    }
}

/// 文件夹页「＋」菜单背后的状态与操作：新建文件夹、从「文件」导入、从相册导入（X3）。
/// 放在一个对象里，是因为空文件夹页的按钮和工具栏菜单触发的是同一套弹窗。
@Observable
@MainActor
final class FolderActions {
    struct Notice: Equatable {
        var title: String
        var message: String
    }

    var showNewFolder = false
    var newFolderName = ""
    var showFileImporter = false
    var showPhotosPicker = false
    var photoSelection: [PhotosPickerItem] = []
    var showSettings = false
    var notice: Notice?

    func askNewFolder() {
        newFolderName = ""
        showNewFolder = true
    }

    func createFolder(in path: String, files: LibraryFiles?) {
        guard let files else { return }
        let name = newFolderName
        Task {
            do {
                _ = try await files.createFolder(named: name, in: path)
            } catch {
                notice = Notice(title: "无法新建文件夹", message: error.localizedDescription)
            }
        }
    }

    func importFiles(_ result: Result<[URL], Error>, into path: String, files: LibraryFiles?) {
        switch result {
        case .failure(let error):
            notice = Notice(title: "导入失败", message: error.localizedDescription)
        case .success(let urls):
            run(urls, into: path, files: files, cleanup: [])
        }
    }

    func importPhotos(_ items: [PhotosPickerItem], into path: String, files: LibraryFiles?) {
        guard !items.isEmpty else { return }
        photoSelection = []
        Task {
            var urls: [URL] = []
            var loadFailed = 0
            for item in items {
                if let video = try? await item.loadTransferable(type: PickedVideo.self) {
                    urls.append(video.url)
                } else {
                    loadFailed += 1
                }
            }
            // 临时文件的目录一并清掉（每个视频一个独立目录）
            run(urls, into: path, files: files, cleanup: urls.map { $0.deletingLastPathComponent() },
                extraFailed: loadFailed)
        }
    }

    private func run(_ urls: [URL], into path: String, files: LibraryFiles?, cleanup: [URL], extraFailed: Int = 0) {
        guard let files else { return }
        Task {
            defer { for dir in cleanup { try? FileManager.default.removeItem(at: dir) } }
            do {
                let result = try await files.importFiles(urls, into: path)
                let songs = result.imported.filter { LibraryScan.isMedia($0.lastPathComponent) }.count
                notice = Notice(
                    title: "导入完成",
                    message: ImportSummary.message(
                        imported: songs, skipped: result.skipped.count, failed: result.failed.count + extraFailed))
            } catch {
                notice = Notice(title: "导入失败", message: error.localizedDescription)
            }
        }
    }
}

/// 挂上新建文件夹弹窗、文件选择器、相册选择器和结果提示
struct FolderActionsModifier: ViewModifier {
    @Bindable var actions: FolderActions
    let path: String
    @Environment(LibraryRoot.self) private var root

    func body(content: Content) -> some View {
        content
            .alert("新建文件夹", isPresented: $actions.showNewFolder) {
                TextField("文件夹名称", text: $actions.newFolderName)
                Button("取消", role: .cancel) {}
                Button("创建") { actions.createFolder(in: path, files: root.files) }
            }
            .fileImporter(
                isPresented: $actions.showFileImporter,
                allowedContentTypes: [.audio, .movie],
                allowsMultipleSelection: true
            ) { result in
                actions.importFiles(result, into: path, files: root.files)
            }
            .photosPicker(
                isPresented: $actions.showPhotosPicker,
                selection: $actions.photoSelection,
                matching: .videos
            )
            .onChange(of: actions.photoSelection) { _, items in
                actions.importPhotos(items, into: path, files: root.files)
            }
            .alert(actions.notice?.title ?? "", isPresented: noticeBinding) {
                Button("好") {}
            } message: {
                Text(actions.notice?.message ?? "")
            }
    }

    private var noticeBinding: Binding<Bool> {
        Binding(get: { actions.notice != nil }, set: { if !$0 { actions.notice = nil } })
    }
}
