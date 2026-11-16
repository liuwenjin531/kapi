import Foundation

extension PlayMode {
    /// 播放页控制行右侧按钮的图标
    var icon: String {
        switch self {
        case .sequential: "repeat"
        case .repeatOne: "repeat.1"
        case .shuffle: "shuffle"
        }
    }

    /// 队列页副标题里的模式名
    var label: String {
        switch self {
        case .sequential: "循环顺序"
        case .repeatOne: "单曲循环"
        case .shuffle: "随机播放"
        }
    }
}
