import Foundation
import Observation
import os

/// 「收到文件」的待处理状态：从「用其他应用打开」、隔空投送、分享扩展收件箱来的文件，
/// 先攒在这里，攒齐后弹 `ReceiveFilesSheet` 让用户选放到哪个文件夹。
///
/// 弹不弹由 App 层决定（乐库没就绪时先存着），这里只管攒批和清理。
@Observable
@MainActor
final class ReceivedFiles {
    private static let log = Logger(subsystem: "com.liuwenjin.kapi", category: "receive")

    /// 当前这一批待导入的文件
    private(set) var urls: [URL] = []
    /// 攒批结束、该弹 sheet 了。弹出之后又来的文件直接追加进 `urls`，不再动这个标志，
    /// 否则 sheet 会在用户眼前闪退再重开
    private(set) var isPresented = false

    /// 这一批已经导入过了（sheet 正显示结果）。此后收起 sheet 不能再按「取消」处理：
    /// 分享收件箱里导入失败的文件要留着下次再试
    private(set) var completed = false

    private var settleTask: Task<Void, Never>?

    /// 一次分享多个文件时系统连续调多次 onOpenURL，间隔很短；等这么久没有新的再弹
    nonisolated static let settleDelay: Duration = .milliseconds(400)

    func add(_ incoming: [URL]) {
        let merged = ReceiveFilesLogic.merge(urls, with: incoming)
        guard merged.count != urls.count else { return }
        urls = merged
        guard !isPresented else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            // 被后一次 add 取消时直接返回，由后一次重新计时
            guard (try? await Task.sleep(for: Self.settleDelay)) != nil else { return }
            self?.isPresented = true
        }
    }

    func markCompleted() { completed = true }

    /// 用户收起 sheet（取消、下滑、点「完成」）。没导入过就当取消，清掉我们放进来的全部临时副本
    func dismiss() {
        guard !completed else { return finish(removing: []) }
        finish(removing: ReceiveFilesLogic.removable(
            all: urls, failed: [], systemInbox: Self.systemInbox, shareInbox: ShareInbox.root
        ))
    }

    /// 清掉这一批并收起 sheet。导入完成时临时副本已经清过，传空即可：收起 sheet、清掉这一批，并删掉我们自己放进来的临时副本
    func finish(removing removable: [URL]) {
        settleTask?.cancel()
        settleTask = nil
        isPresented = false
        completed = false
        urls = []
        Self.cleanup(removable)
    }

    /// 系统 Inbox 的位置（沙盒 `Documents/Inbox/`）。iCloud 模式下它在乐库之外，本机模式下在乐库根目录里
    nonisolated static var systemInbox: URL {
        URL.documentsDirectory.appending(path: ReceiveFilesLogic.systemInboxName, directoryHint: .isDirectory)
    }

    /// 删临时副本：只删系统 Inbox 和分享收件箱里的，别处原地打开的原文件一律不动
    static func cleanup(_ files: [URL]) {
        for url in files {
            switch ReceiveFilesLogic.origin(of: url, systemInbox: systemInbox, shareInbox: ShareInbox.root) {
            case .systemInbox:
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    log.error("清理 Inbox 文件失败：\(error.localizedDescription)")
                }
            case .shareInbox:
                ShareInbox.remove(url)
            case .external:
                break
            }
        }
    }
}
