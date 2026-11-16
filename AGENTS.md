# Kapi（卡皮音乐）3.0

iPhone 本地音乐播放器。乐库二选一：iCloud 云盘里的「卡皮音乐」文件夹（推荐），或这台 iPhone 本机的 App 文档目录；用户在「文件」App 或电脑上整理，App 里所见即所得。首次启动让用户选，之后可在设置里切换，两边是完全独立的两套乐库；只做 iPhone（含 iPhone Duo），不做 macOS、iPad；最低 iOS 27.0。

## 工程

- 用 xcodegen：`project.yml` 是唯一事实来源，`Kapi.xcodeproj`、`Config/`（生成的 Info.plist 与 entitlements）不入库。改签名、标识、Info.plist 项、权限一律改 `project.yml` 再 `xcodegen generate`，在 Xcode 界面里改会被冲掉。
- Swift 6 语言模式；SwiftUI；`@Observable`；**不引入任何第三方库**。
- target：`Kapi`（App）、`KapiShare`（分享扩展）、`KapiWidgets`（主屏幕「正在播放」小组件）、`KapiTests`（纯逻辑单元测试）。
- 标识一经上架不能改：

| 用途 | 值 |
|---|---|
| 主 App | `com.liuwenjin.kapi` |
| 分享扩展 | `com.liuwenjin.kapi.share` |
| 小组件扩展 | `com.liuwenjin.kapi.widgets` |
| App Group | `group.com.liuwenjin.kapi` |
| iCloud 容器 | `iCloud.com.liuwenjin.kapi`（只给主 App） |
| 显示名 | 卡皮音乐 |
| 版本 | `MARKETING_VERSION 3.0`，build 号从 1 起；改了 `NSUbiquitousContainers` 要提高 build 号 |

## 目录

```
Sources/
├── App/        入口、环境注入
├── Storage/    iCloud 容器、文件监听、状态文件读写
├── Library/    扫描、文件夹树、曲目元数据、缩略图缓存
├── Playlists/  歌单与最爱
├── Playback/   播放器、歌词、睡眠定时、锁屏信息、写给小组件的快照（WidgetBridge）
├── Widget/     主 App 和小组件共用：快照模型、时间线、Intent、跳转链接（同时编进两个 target）
├── UI/         Common / Playlists / Folder / Search / Player / Settings
└── Resources/  Assets、PrivacyInfo.xcprivacy
ShareExtension/ 分享扩展（自带 PrivacyInfo.xcprivacy）
Widgets/        小组件扩展（自带 PrivacyInfo.xcprivacy）
Tests/          纯逻辑测试
```

## 编码约定

- 一个文件一个主要类型；文件名 = 类型名。
- 主线程只做界面；文件读写、元数据解析、iCloud 查询处理放后台（`Task` / actor）。
- 不吞错误：`try?` 只用在「失败了也无所谓」的地方并注释说明；其余错误要么提示用户，要么记日志（`os.Logger`，子系统 `com.liuwenjin.kapi`）。
- 不写死设备尺寸；布局用安全区、size class 和系统容器。导航栏、工具栏、返回、菜单、alert、sheet 一律用系统控件，工具栏按钮用 `Label`（文字 + SF Symbol）。
- 字符串直接写中文（只支持简体中文），不做多语言。
- 注释用中文，写「为什么这么做」，尤其是踩过的坑，不写「是什么」。
- 纯逻辑（文件夹树、主键认领、排序、歌单 JSON 编解码、歌词解析）写单元测试，放 `Tests/`。
- 歌曲行的操作统一走 `.songActions(for:swipe:)`（`Sources/UI/Common/SongActions.swift`）：长按菜单 + `List` 里的左右滑动（右滑最爱、左滑加到歌单）。`.swipeActions` 只对 `List` 的行生效，所以带滑动的歌曲列表必须是 `List`，行用 `.plainListRow()` 还原外观；方格里的歌曲行只有长按菜单。「播放下一首」「删除」不放进滑动：App 没有用户可见的播放队列，删除在 iCloud 里不可恢复。
- 依赖播放进度（`player.currentTime`，播放时每 0.25 秒变一次）的界面，放进独立小视图自己去读，不要放进整页的 body：整页每秒重算几次，页上的菜单会被反复重建（见 `Sources/UI/Player/PlayerLiveViews.swift`）。
- 颜色统一走 `Theme`：浅色背景 `#F6F2EA`、强调色海豹咖 `#6F4E37`；深色背景 `#0D0F13`、强调色柠檬绿 `#CDEB5A`。外观只有浅色、深色两项，没有「跟随系统」。

## 存储约定

- 乐库位置由 `LibraryRoot.Location`（`icloud` / `local`）决定，选择记在 UserDefaults 的 `libraryLocation`：iCloud 时根目录是 iCloud 容器的 `Documents/`，本机时是沙盒 `Documents/`（开了 `UIFileSharingEnabled`，「文件 › 我的 iPhone › 卡皮音乐」可见）。两边各自的歌单、最爱互不影响。
- 歌单、最爱放乐库根目录下的 `.kapi/`（`playlists.json`、`favorites.json`、`covers/`），以点开头，「文件」App 里看不到。
- 曲目主键 = 相对 `Documents/` 的路径。歌被挪动后，靠「文件名 + 文件大小」认领歌单里的旧路径；找不到的条目不删，显示时跳过。
- iCloud 乐库用 `NSMetadataQuery` 列文件，不自己遍历；本机乐库没有变化推送，由 `LocalLibraryQuery` 遍历目录，并在启动、回到前台、App 自己改了文件时重扫；两者都实现 `LibrarySource`。**没下载的文件不读标签**（会触发整首下载）。
- 状态文件读写走 `NSFileCoordinator`，整文件覆盖，写前先读最新版；云上还没下载到本机时不写。JSON 带 `version`，读到比自己新的版本只读不写。

## 小组件

- 小组件是另一个进程，只靠主 App 写进 App Group 的快照（`Widget/now-playing.json`）和封面缩略图（`Widget/cover.jpg`）画界面，不碰 iCloud 容器。快照只在「小组件看得出区别」时才写（`WidgetSnapshot.isEquivalent`），刷新次数有系统预算，不要跟着播放进度每秒写。
- 播放中的进度条用系统自走的 `ProgressView(timerInterval:)`，不靠刷新。快照停在「播放中」而 App 已被杀时，时间线里「预计结束时间后切空闲态」的条目兜底，改时间线逻辑要保住这一条。
- 小组件按钮是 `AudioPlaybackIntent`，由系统放到主 App 的进程里执行，经 `PlaybackCommandBus` 转给 `PlayerService.shared`。播放器必须通过 `PlayerService.shared` 取，不要在 App 层另建实例。
- 配色按快照里的 `skin` 取（`Theme.palette`），不跟随系统外观。新增小组件用到的颜色，在 `Theme` 里和动态色共用同一份色值。
- 点击跳转用自定义链接 `kapi://player`、`kapi://favorites/play`（`WidgetLink`），只触发无害动作，别加会删除或改写数据的链接。

## 隐私与权限

- Info.plist 里**不得出现任何 `NS…UsageDescription`**：相册导入用 `PhotosPicker`，文件导入用 `fileImporter`，搜索框不放话筒，App 不联网。
- 已声明：`UIBackgroundModes: [audio]`、`ITSAppUsesNonExemptEncryption: false`、`CFBundleDevelopmentRegion: zh-Hans`。
- 主 App 和分享扩展各有一份 `PrivacyInfo.xcprivacy`：不追踪、不收集数据，`NSPrivacyAccessedAPITypes` 只列实际用到的 API。不要用磁盘剩余空间、系统开机时间这两类 API。
