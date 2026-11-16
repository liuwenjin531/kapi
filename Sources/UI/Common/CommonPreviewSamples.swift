import Foundation

/// 预览用的假数据，不读真实文件。只给 `Sources/UI/Common` 下的 #Preview 用，不参与运行逻辑。
enum CommonPreviewSamples {
    static func track(_ title: String, format: String, megabytes: Double, duration: TimeInterval, folder: String = "") -> Track {
        let file = "\(title).\(format.lowercased())"
        let path = folder.isEmpty ? file : "\(folder)/\(file)"
        return Track(
            path: path,
            url: URL(fileURLWithPath: "/dev/null/\(path)"),
            title: title,
            artist: nil,
            duration: duration,
            fileSize: Int64(megabytes * 1_048_576),
            format: format,
            hasVideo: false,
            videoAspect: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            isDownloaded: true
        )
    }

    static let songs: [Track] = [
        track("夜航船", format: "FLAC", megabytes: 27.8, duration: 222),
        track("国道 318", format: "MP3", megabytes: 9.2, duration: 231, folder: "华语"),
        track("旧街灯", format: "FLAC", megabytes: 29.2, duration: 234, folder: "华语/怀旧"),
        track("春分", format: "M4A", megabytes: 6.5, duration: 252, folder: "华语/怀旧"),
        track("夜色温柔", format: "M4A", megabytes: 6.3, duration: 245, folder: "华语/怀旧"),
    ]

    /// 由上面的歌曲建出的文件夹树，供拼图和文件夹行预览
    static let folder: FolderNode = FolderNode.build(from: songs)

    static let playlist = Playlist(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
        name: "通勤路上",
        cover: nil,
        items: songs.map(\.path),
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        lastPlayedAt: nil
    )
}
