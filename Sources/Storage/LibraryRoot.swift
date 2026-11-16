import Foundation
import Observation
import UIKit

/// 乐库根目录从哪来、现在能不能用。
///
/// 根目录有两种来源：本机沙盒 `Documents/`，或 iCloud 容器里的 `Documents/`。
/// 首次启动由用户选，之后随时能在设置里切换。两边是完全独立的两套：
/// 歌、歌单、最爱都在各自的 `Documents/.kapi/` 下，切换只是换一个根目录来读，哪边都不删。
/// 之后的歌单、扫描、导入、删除都只认 `documentsURL`，不关心它在哪。
@Observable
@MainActor
final class LibraryRoot {
    /// 乐库放在哪。存在 UserDefaults 的 `libraryLocation` 键里，首次选择页和设置页写它
    enum Location: String, CaseIterable, Sendable {
        case icloud, local

        nonisolated static let defaultsKey = "libraryLocation"

        /// 用户选过的位置；还没选过（首次启动）是 nil
        static var chosen: Location? {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(Location.init(rawValue:))
        }

        /// 当前位置；还没选时按 iCloud 算（只影响首次选择之前的提示文案）
        static var stored: Location { chosen ?? .icloud }

        var title: String { self == .icloud ? "iCloud 云盘" : "本机" }
        var symbol: String { self == .icloud ? "icloud" : "iphone" }

        /// 删除确认框里的补充一句：只有 iCloud 会同步删到其他设备，本机模式说了反而误导
        var deletionSyncNote: String {
            self == .icloud ? "其他设备上也会一起删除。" : ""
        }
    }

    enum State: Equatable {
        /// 首次启动，还没选乐库放在哪：显示选择页
        case needsChoice
        /// 正在向系统要容器、创建 `Documents/` 与 `.kapi/`。首次启动会停留一会儿，显示「正在准备」
        case preparing
        /// 没登录 iCloud、关了 iCloud 云盘或关了本 App 的 iCloud：显示报错页，回到前台自动重试。
        /// 本机模式下只有建不出目录（磁盘满）才会走到这里
        case unavailable
        /// 可用。关联值是容器里的 `Documents/`，也就是乐库根目录
        case ready(documentsURL: URL)
    }

    /// 容器标识，必须和 `project.yml` 里的 entitlements 一致（建好后不能改名）
    nonisolated static let containerIdentifier = "iCloud.com.liuwenjin.kapi"

    private(set) var state: State = .preparing
    /// 当前乐库位置。切换走 `choose(_:)`；换根目录牵涉的扫描、歌单、播放队列由 App 层监听它统一重来
    private(set) var location: Location = Location.stored
    /// 用户是否选过位置。没选过时 `start()` 停在选择页
    private(set) var hasChosen = Location.chosen != nil

    /// 乐库根目录，仅 `ready` 时有值
    var documentsURL: URL? {
        if case .ready(let url) = state { return url }
        return nil
    }

    /// 文件操作（新建文件夹 / 导入 / 删除），仅 `ready` 时有值
    var files: LibraryFiles? {
        documentsURL.map { LibraryFiles(documentsURL: $0) }
    }

    private var started = false
    private var isResolving = false
    /// 解析期间又来了一次 refresh（比如账号刚切换）：跑完这轮再补一轮，不丢
    private var needsAnotherPass = false

    /// 启动流程：后台拿到根目录，确保 `Documents/`、`Documents/.kapi/` 存在。
    /// 监听 `NSUbiquityIdentityDidChange` 与回到前台，只在 iCloud 模式下才重试；
    /// 观察者一律注册，因为运行中随时可能从本机切到 iCloud
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        // 观察者随 App 生命周期，不需要移除。回调已在主队列，用 assumeIsolated 回到主 actor
        center.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfICloud() }
        }
        // 用户去设置里打开 iCloud 再回来：靠这个自动恢复，不用手动点重试
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfICloud() }
        }
        guard hasChosen else {
            state = .needsChoice
            return
        }
        refresh()
    }

    /// 选定（首次）或切换乐库位置。记下来，回到「正在准备」，再去拿新的根目录
    func choose(_ newLocation: Location) {
        UserDefaults.standard.set(newLocation.rawValue, forKey: Location.defaultsKey)
        hasChosen = true
        guard newLocation != location || state == .needsChoice || state == .unavailable else { return }
        location = newLocation
        state = .preparing
        refresh()
    }

    /// 本机目录不会凭空消失，只有 iCloud 需要跟着账号变化、回前台重试
    private func refreshIfICloud() {
        guard hasChosen, location == .icloud else { return }
        refresh()
    }

    /// 再试一次。回到前台、iCloud 账号变化、用户点「重试」时调用。
    func refresh() {
        guard hasChosen else { return }
        guard !isResolving else {
            needsAnotherPass = true
            return
        }
        isResolving = true
        let target = location
        Task {
            let documents = await Self.resolveDocuments(in: target)
            isResolving = false
            // 拿目录的几秒里用户又切了位置：这次的结果作废，按新位置再来一遍
            guard target == location else {
                needsAnotherPass = false
                refresh()
                return
            }
            let next: State = documents.map { .ready(documentsURL: $0) } ?? .unavailable
            // 已经 ready 且地址没变就不赋值：每次回前台都赋一遍会让整个界面树白白失效
            if next != state { state = next }
            if needsAnotherPass {
                needsAnotherPass = false
                refresh()
            }
        }
    }

    /// 拿到根目录并建好目录；失败返回 nil。
    /// `@concurrent` 保证跑在后台：iCloud 首次要容器可能要几秒（系统在初始化容器）
    @concurrent
    private static func resolveDocuments(in location: Location) async -> URL? {
        let fm = FileManager.default
        let documents: URL
        switch location {
        case .local:
            // 沙盒 Documents/ 开了 UIFileSharingEnabled，「文件 › 我的 iPhone › 卡皮音乐」里能直接看到、拖歌进来
            guard let url = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
            documents = url
        case .icloud:
            guard let container = fm.url(forUbiquityContainerIdentifier: containerIdentifier) else { return nil }
            documents = container.appending(path: "Documents", directoryHint: .isDirectory)
        }
        let hidden = documents.appending(path: ".kapi", directoryHint: .isDirectory)
        do {
            // 歌单数据放 .kapi/。iCloud 下还有一层原因：「文件」App 里要 Documents/ 里至少有一个东西，
            // 卡皮音乐文件夹才会出现，所以连 .kapi/ 一起建
            try fm.createDirectory(at: hidden, withIntermediateDirectories: true)
        } catch {
            // 容器给了但建不出目录（磁盘满、权限异常）：和不可用同样处理，让用户看到报错页而不是空白
            return nil
        }
        return documents
    }
}
