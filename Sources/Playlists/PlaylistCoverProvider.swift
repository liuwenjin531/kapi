import SwiftUI
import UIKit

/// 歌单自己的封面图（`Documents/.kapi/covers/<id>.jpg`）的读取与内存缓存。
///
/// 封面存在 iCloud 容器里，读盘不便宜，列表滚动时同一张图会被反复要，所以放内存缓存。
/// 缓存键带上 `updatedAt`：换封面会刷新它，旧图自然失效，不用手动清。
@MainActor
final class PlaylistCoverProvider {
    private var documentsURL: URL?
    private let cache = NSCache<NSString, UIImage>()

    /// 环境默认值（预览、测试）要在非隔离上下文里创建，所以 init 标 nonisolated：它不碰任何主线程状态
    nonisolated init() {}

    /// `Documents/` 变了（换账号）就丢掉旧缓存
    func attach(documentsURL: URL?) {
        guard documentsURL != self.documentsURL else { return }
        self.documentsURL = documentsURL
        cache.removeAllObjects()
    }

    /// 歌单的自定义封面；没设置封面或读不到文件返回 nil（调用方再退到第一首歌的封面）。
    /// 解码放到后台：封面最长边 1024，主线程解几张会掉帧
    func image(for playlist: Playlist) async -> UIImage? {
        guard let relative = playlist.cover, let documentsURL else { return nil }
        let key = "\(playlist.id.uuidString)-\(playlist.updatedAt.timeIntervalSince1970)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = documentsURL.appending(path: ".kapi").appending(path: relative)
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)?.preparingForDisplay()
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

extension EnvironmentValues {
    /// 默认值只给预览和测试用，真实的由 App 层注入。
    /// 放成静态常量是为了不让 `@Entry` 每次读取都新建一个对象
    private static let defaultPlaylistCovers = PlaylistCoverProvider()
    @Entry var playlistCovers: PlaylistCoverProvider = defaultPlaylistCovers
}

/// 歌单封面：自定义图 → 第一首歌的封面 → 占位色块（封面三级回退）。
/// `PlaylistRow` / `PlaylistGridCard` 只认「一首歌的封面」，自定义图由本视图盖在它们的封面位置上，
/// 所以这里同时负责判断「要不要盖」：没有自定义图时不画任何东西，露出底下组件自己的封面
struct PlaylistCustomCover: View {
    let playlist: Playlist

    @Environment(\.playlistCovers) private var covers
    @State private var loaded: Loaded?

    private struct Loaded {
        let key: String
        let image: UIImage
    }

    private var key: String { "\(playlist.id)-\(playlist.cover ?? "")-\(playlist.updatedAt.timeIntervalSince1970)" }

    var body: some View {
        // 先铺一个透明正方形再按它的实际边长画图：行里是固定 68，方格里边长由列宽决定，两处共用
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    if let loaded, loaded.key == key {
                        Image(uiImage: loaded.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: coverRadius(for: geo.size.width), style: .continuous))
                    }
                }
            }
            .accessibilityHidden(true)
        .task(id: key) {
            let image = await covers.image(for: playlist)
            loaded = image.map { Loaded(key: key, image: $0) }
        }
    }
}
