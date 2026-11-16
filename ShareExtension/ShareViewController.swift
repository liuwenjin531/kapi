import UIKit
import UniformTypeIdentifiers

/// 系统分享面板里的「卡皮音乐」。
/// 扩展碰不到主 App 的沙盒（也不碰 iCloud 容器，没有那个权限），
/// 所以这里只负责把文件落进 App Group 共享容器，真正导入乐库由主 App 下次回到前台时完成
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        label.text = "正在加入卡皮音乐…"
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
        ])

        Task { await run() }
    }

    private func run() async {
        var saved = 0
        for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
            for provider in item.attachments ?? [] where await save(provider) {
                saved += 1
            }
        }
        // 面板一关就没有别的反馈了，成没成得在这儿说一声
        label.text = saved > 0 ? "已加入 \(saved) 个，打开卡皮音乐后导入" : "没有可导入的音视频或歌词"
        // 睡眠被取消也照样收起面板
        try? await Task.sleep(for: .seconds(0.9))
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func save(_ provider: NSItemProvider) async -> Bool {
        // 一份附件常注册多个类型（比如 mp4 同时报 public.movie 和 public.mpeg-4），
        // 挑第一个是音视频的去要文件就行；.lrc 歌词认 project.yml 里声明的专用类型，
        // 找不到时再认「按扩展名 lrc 推出的类型」，下面拿到文件后还会核对扩展名
        let lyricTypes = [UTType("com.liuwenjin.kapi.lrc"), UTType(filenameExtension: "lrc")].compactMap { $0 }
        let mediaType = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .audiovisualContent) ?? false
        }
        let lyricType = provider.registeredTypeIdentifiers.first { id in
            guard let type = UTType(id) else { return false }
            return lyricTypes.contains { type.conforms(to: $0) }
        }
        guard let type = mediaType ?? lyricType else { return false }
        let isLyric = mediaType == nil

        return await withCheckedContinuation { done in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                // url 只在这个回调期间有效，必须当场拷走。
                // 歌词类型可能被别的文本误匹配，扩展名不是 lrc 的不收
                guard let url, !isLyric || url.pathExtension.lowercased() == "lrc", let slot = ShareInbox.makeSlot() else {
                    done.resume(returning: false)
                    return
                }
                let dest = slot.appending(path: url.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    done.resume(returning: true)
                } catch {
                    // 拷失败（共享容器满了）：清掉这个空目录，别留垃圾
                    try? FileManager.default.removeItem(at: slot)
                    done.resume(returning: false)
                }
            }
        }
    }
}
