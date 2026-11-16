import SwiftUI
import WidgetKit

@main
struct KapiWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}

/// 「正在播放」小组件：小号（方形封面铺满）和中号（封面 + 三个播放按钮）。
/// 没有可配置项，所以用 StaticConfiguration
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.widgetKind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("正在播放")
        .description("显示正在播放的歌曲，直接暂停、切歌。")
        .supportedFamilies([.systemSmall, .systemMedium])
        // 封面要铺满到小组件边缘，内容边距由各视图自己留
        .contentMarginsDisabled()
    }
}
