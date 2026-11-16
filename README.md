# 卡皮音乐

iPhone（含 iPhone Duo）音乐播放器。为爱发电，永久免费。

乐库二选一：iCloud 云盘里的「卡皮音乐」文件夹，或这台 iPhone 本机的文件夹。首次启动时选择，之后可在设置里切换，两边是完全独立的两套乐库。在「文件」App 或电脑上整理，App 里所见即所得。不联网，不收集任何数据。需要 iOS 27.0 及以上。

## 跑起来

需要 Xcode 和 [xcodegen](https://github.com/yonaskolb/XcodeGen)：

```bash
xcodegen generate && open Kapi.xcodeproj
```

`Kapi.xcodeproj` 和 `Config/` 由 `project.yml` 生成，不入库。**改构建设置只改 `project.yml`**，
在 Xcode 界面里改会被下一次生成冲掉。`Sources/` 下新增或删除文件后重新生成一次。

iCloud 乐库需要付费开发者账号签名，运行设备或模拟器要登录 Apple ID 并打开 iCloud 云盘；本机乐库不需要。

## 命令行检查（不生成工程）

```bash
xcrun -sdk iphonesimulator swiftc -typecheck -swift-version 6 \
  -target arm64-apple-ios27.0-simulator $(find Sources -name '*.swift')
```

单元测试：生成工程后在 Xcode 里跑 `Kapi` scheme 的测试，或

```bash
xcodebuild test -scheme Kapi -destination 'platform=iOS Simulator,name=<iPhone 机型>'
```

## 目录

见 [AGENTS.md](AGENTS.md)。

## 许可与品牌

代码按 [MIT 许可证](LICENSE) 开源。

「卡皮音乐」这个名称和 App 图标（`Sources/Resources/Assets.xcassets/AppIcon.appiconset`）不在 MIT 许可范围内，作者保留全部权利。你可以学习、修改、再发布代码，但不要用同样的名称和图标重新打包后上架，也不要让人误以为是官方版本。基于本项目做自己的 App，请换一个名字和图标。

本机自行构建时，需要把 `project.yml` 里的 Team ID（`DEVELOPMENT_TEAM`）、Bundle ID、App Group、iCloud 容器改成你自己的，再运行 `xcodegen generate`。

隐私政策见 [PRIVACY.md](PRIVACY.md)，技术支持见 [SUPPORT.md](SUPPORT.md)。
