# 技术支持 · Support

## 中文

### 遇到问题

到 GitHub Issues 反馈：https://github.com/liuwenjin531/kapi/issues

提问前先看下面的常见问题。提 Issue 时请写清：

- iPhone 机型和 iOS 版本
- 卡皮音乐的版本（App 里「设置 › 关于」）
- 乐库放在 iCloud 还是本机
- 怎么操作会出问题

Issue 是公开的，请不要贴个人信息，也不要上传你的歌曲文件。

### 常见问题

**乐库放在哪里？**

第一次打开时二选一，之后可以在「设置 › 乐库位置」里切换。

- iCloud 云盘：在「文件」App 的「iCloud 云盘 › 卡皮音乐」。多台设备同步。
- 本机：在「文件」App 的「我的 iPhone › 卡皮音乐」。不同步。

两边各有一套歌曲和歌单，互不影响。切换只是换一个文件夹来读，哪边的东西都不会被删。App 里看到的就是这个文件夹里的内容，在「文件」App 里整理，App 里同步变化。

**怎么把歌放进本机乐库？**

任选一种：

1. 在「文件」App 里，把歌拖进或拷贝到「我的 iPhone › 卡皮音乐」。
2. 在 App 里打开一个文件夹，点右上角「＋」，选「从「文件」导入」；视频可以选「从相册导入」。
3. 在别的 App（比如微信）或隔空投送里，把音频分享给卡皮音乐，选好放进哪个文件夹。

支持的格式：mp3、m4a、aac、flac、wav、aiff、alac、caf、m4b，以及视频 mp4、m4v、mov。

**iCloud 里的歌显示一个云朵箭头，没下载怎么办？**

这是正常的：歌还在 iCloud 里，没存到这台 iPhone 上。点它，App 会开始下载，下完就能播，需要联网。几点说明：

- 没下载的歌，标题、歌手、封面可能暂时显示不全，下载后才完整。App 不会为了读这些信息去整首下载。
- 一直下不来：检查网络，并确认「设置 › Apple 账户 › iCloud」里已打开「iCloud 云盘」和「卡皮音乐」。
- 想离线听：在「文件」App 里对歌曲或文件夹长按，选「下载」。
- 提示无法使用 iCloud：按页面提示登录 Apple 账户并打开 iCloud 云盘，或者在 App 里改用本机存储。

**歌词（LRC）怎么放？**

把歌词文件放在歌曲旁边，和歌曲同一个文件夹，文件名除了后缀相同，后缀改成 `.lrc`。例如：

```
旅行/夜航船.mp3
旅行/夜航船.lrc
```

播放页就会显示歌词。几点说明：

- 歌词需要带时间标签（如 `[01:23.45]歌词`），没有时间标签的歌词不会显示。
- 编码支持 UTF-8、GB18030、UTF-16。
- 在 App 里移动或改名歌曲时，同名 `.lrc` 会一起处理。在「文件」App 里自己改名的话，要把 `.lrc` 也改成一样的名字。
- 歌词比歌早或晚，可以在播放页里微调时间，不会改你的 `.lrc` 文件。
- 歌词文件也可以和歌一起导入或分享给卡皮音乐，放进你选的文件夹。一起导入时，歌如果因重名被加了「 2」，歌词会跟着对齐。

---

## English

### Getting help

Report problems on GitHub Issues: https://github.com/liuwenjin531/kapi/issues

Please check the FAQ below first. When you open an issue, include:

- Your iPhone model and iOS version
- The Kapi Music version (Settings › About in the app)
- Whether your library is in iCloud or on this iPhone
- The steps that lead to the problem

Issues are public. Please do not post personal information, and do not upload your song files.

### FAQ

**Where is my library?**

You choose one of two places on first launch, and can switch later in Settings › Library Location.

- iCloud Drive: in the Files app, under "iCloud Drive › 卡皮音乐". Synced across your devices.
- On this iPhone: in the Files app, under "On My iPhone › 卡皮音乐". Not synced.

The two places hold separate songs and playlists. Switching only changes which folder the app reads; nothing is deleted on either side. What you see in the app is what is in that folder. Organize files in the Files app and the app follows.

**How do I add songs to the on-device library?**

Any one of these:

1. In the Files app, drag or copy songs into "On My iPhone › 卡皮音乐".
2. In the app, open a folder, tap "＋" at the top right, and choose "从「文件」导入" (Import from Files). For videos, you can choose "从相册导入" (Import from Photos).
3. From another app (WeChat, for example) or AirDrop, share the audio file to Kapi Music and pick the destination folder.

Supported formats: mp3, m4a, aac, flac, wav, aiff, alac, caf, m4b, and video files mp4, m4v, mov.

**A song in iCloud shows a cloud-with-arrow icon and will not play. What now?**

This is normal. The song is in iCloud but not yet stored on this iPhone. Tap it and the app starts downloading it; once downloaded it plays. You need a network connection. Notes:

- Until a song is downloaded, its title, artist and cover may be incomplete. The app does not download a whole song just to read those.
- If the download never finishes, check your network, and check that "iCloud Drive" and "卡皮音乐" are turned on in Settings › Apple Account › iCloud.
- To keep songs available offline, long-press a song or folder in the Files app and choose "Download Now".
- If the app says iCloud is unavailable, sign in to your Apple Account and turn on iCloud Drive, or switch to on-device storage in the app.

**How do I add lyrics (LRC)?**

Put the lyrics file next to the song, in the same folder, with the same name but the extension `.lrc`. For example:

```
旅行/夜航船.mp3
旅行/夜航船.lrc
```

The lyrics then show on the Now Playing screen. Notes:

- Lyrics need time tags (such as `[01:23.45]text`). Lines without time tags are not shown.
- Supported encodings: UTF-8, GB18030, UTF-16.
- When you move or rename a song inside the app, its matching `.lrc` is moved or renamed with it. If you rename a song yourself in the Files app, rename the `.lrc` to match.
- If lyrics run early or late, adjust the timing on the Now Playing screen. This does not modify your `.lrc` file.
- Lyrics files can be imported or shared to Kapi Music together with the songs, into the folder you choose. If a song gets a " 2" added because of a name clash, its lyrics file is renamed to match.
