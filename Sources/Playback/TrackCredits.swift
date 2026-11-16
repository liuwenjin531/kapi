import AVFoundation

/// 播放页「词曲」那一行的来源：读文件标签里的词作者 / 曲作者。
/// `Track` 不带这两项（乐库层只读标题、艺人、时长），播放页自己按需读，读不到就不显示这一行
enum TrackCredits {
    /// 返回「词曲」后面的文字，如 `青禾`、`青禾 / 林夕`；标签里没有返回 nil。
    /// 没下载的文件不读：读标签会触发整首下载，等下载完调用方再来问
    static func load(for track: Track) async -> String? {
        let url = track.url
        guard await Task.detached(priority: .utility, operation: { isOnDevice(url) }).value else { return nil }

        let asset = AVURLAsset(url: url)
        // 读不了标签（格式不支持、文件损坏）就当没有，不影响播放
        guard let items = try? await asset.load(.metadata) else { return nil }

        var names: [String] = []
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                guard let text = try? await item.load(.stringValue) else { continue }
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !names.contains(name) { names.append(name) }
            }
        }
        return names.isEmpty ? nil : names.joined(separator: " / ")
    }

    /// 词作者在前、曲作者在后；各容器格式的写法不同，都列上
    private static let identifiers: [AVMetadataIdentifier] = [
        .id3MetadataLyricist, .id3MetadataComposer,
        .iTunesMetadataComposer,
    ]

    private nonisolated static func isOnDevice(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        // 非 iCloud 文件没有这个状态，当作在本机
        return status == nil || status == .current
    }
}
