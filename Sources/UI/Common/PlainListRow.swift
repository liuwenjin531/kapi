import SwiftUI

extension View {
    /// 让 `List` 的一行看起来和原来 `ScrollView` + `LazyVStack` 里的一样：
    /// 没有系统内边距、没有系统分隔线、没有行背景。分隔线由 `SongRow` / `FolderRow` 自己画。
    /// 文件夹页、搜索页、歌单详情页共用，三处的行才会排得一样
    func plainListRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
