import SwiftUI

extension View {
    /// 挂在每个 `NavigationStack` 的根视图上，让 `NavigationLink(value: AppRouter.Destination)` 能推到对应页面。
    /// 统一写在这里，三个 Tab 的栈不用各自重复一遍目的地表
    func appDestinations() -> some View {
        navigationDestination(for: AppRouter.Destination.self) { destination in
            switch destination {
            case .folder(let path):
                FolderView(path: path)
            case .playlist(let id):
                PlaylistDetailView(id: id)
            }
        }
    }
}
