import UIKit

/// 方向控制必须走 AppDelegate：SwiftUI 没有等价入口。
/// 平时锁竖屏，只有全屏看 MV 时 `OrientationGate` 才放开
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationGate.allowsLandscape ? .allButUpsideDown : .portrait
    }
}

/// 方向闸门。
/// Info.plist 里放开了横屏，但只有全屏看 MV 时才真的允许转——否则歌单列表页也会跟着横过来。
/// 应用级的 `UISupportedInterfaceOrientations` 是硬白名单，视图控制器只能在其中收窄不能扩大，
/// 所以想「只让某个页面横屏」必须 plist 放开 + 这里按页面收回来
@MainActor
enum OrientationGate {
    /// AppDelegate 的方向回调在主线程，和这里同一个隔离域
    private(set) static var allowsLandscape = false

    /// - Parameter landscape: 放开时是否顺便主动转成横屏（宽屏视频全屏时要；竖版视频不转）
    static func set(_ allowed: Bool, rotateToLandscape landscape: Bool = false) {
        allowsLandscape = allowed
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        // 改完要主动通知系统重新问一次，否则不会立刻转
        scene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if allowed {
            if landscape { rotate(scene, to: .landscape) }
        } else {
            // 退出全屏时若还横着，把它转回竖屏
            rotate(scene, to: .portrait)
        }
    }

    private static func rotate(_ scene: UIWindowScene?, to mask: UIInterfaceOrientationMask) {
        // 转不动（已是目标方向、或系统拒绝）不影响功能，用户仍可手动转
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}
