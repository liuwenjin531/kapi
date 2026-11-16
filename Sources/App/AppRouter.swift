import SwiftUI
import Observation

/// 全 App 的导航状态：当前 Tab，以及每个 Tab 自己的导航栈。
///
/// 放在 App 层而不是各页面自己管，是因为有跨 Tab 的跳转：
/// 播放页「⋯ › 前往所在文件夹」、搜索结果里点路径，都要切到「乐库」Tab 并一层层推到那个文件夹。
@Observable
@MainActor
final class AppRouter {
    enum TabID: Hashable { case playlists, library, search }

    /// 推进导航栈的目的地。文件夹用相对路径，歌单用 id，都是值类型，方便整栈替换
    enum Destination: Hashable {
        case folder(String)
        case playlist(Playlist.ID)
    }

    /// 小组件点击带来、还没执行的动作。冷启动时乐库还没读完，「播放最爱」得先存着，读完再执行
    var pendingAction: AppLaunchAction?

    var selectedTab: TabID = .library
    var playlistsPath: [Destination] = []
    var libraryPath: [Destination] = []
    var searchPath: [Destination] = []

    /// 切到「乐库」Tab，并把导航栈替换成从根目录一层层到 `folderPath` 的路径，
    /// 这样返回键能逐级回到上一层，而不是直接跳回根目录
    func showFolder(_ folderPath: String) {
        var stack: [Destination] = []
        var walked = ""
        for part in folderPath.split(separator: "/") {
            walked = walked.isEmpty ? String(part) : walked + "/" + part
            stack.append(.folder(walked))
        }
        selectedTab = .library
        libraryPath = stack
    }

    /// 切换乐库位置：各栈里推着的文件夹、歌单都属于旧的那一套，全部退回根页
    func resetPaths() {
        playlistsPath = []
        libraryPath = []
        searchPath = []
    }

    /// 切到「歌单」Tab 并打开某个歌单详情
    func showPlaylist(_ id: Playlist.ID) {
        selectedTab = .playlists
        playlistsPath = [.playlist(id)]
    }
}
