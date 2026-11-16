import Foundation

/// 一句歌词：出现时刻 + 文本
struct LyricLine: Hashable, Sendable {
    let time: TimeInterval
    let text: String
}

/// `.lrc` 歌词的定位、读取与解析。解析部分是纯函数，单元测试在 `Tests/LyricsTests.swift`
enum Lyrics {
    /// 歌词文件就是同名换后缀：`旅行/夜航船.mp3` → `旅行/夜航船.lrc`
    static func url(for track: URL) -> URL {
        track.deletingPathExtension().appendingPathExtension("lrc")
    }

    /// 读同名 `.lrc` 并解析。没文件、或一句带时间戳的都没有，都返回空数组：
    /// 调用方只看空不空，不区分「没文件」和「文件是空的」。
    ///
    /// 歌词文件在 iCloud 里也可能还是占位项（读它会失败或卡住），所以先触发下载、
    /// 轮询等它到本机；几 KB 的文件通常一两秒就到，等不到就当没有，下次进播放页再试。
    /// 调用方用 `.task(id:)` 承载，切歌时任务被取消，这里的轮询随之结束。
    static func load(for track: URL) async -> [LyricLine] {
        let file = url(for: track)
        for attempt in 0..<20 {
            switch await Task.detached(priority: .utility, operation: { availability(of: file) }).value {
            case .missing:
                return []
            case .ready:
                let data = await Task.detached(priority: .utility, operation: { try? Data(contentsOf: file) }).value
                return data.map { parse(decode($0)) } ?? []
            case .remote:
                if attempt == 0 {
                    // 失败也无所谓：下一轮轮询看到仍是占位就继续等，等满了当没有
                    try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                }
                do { try await Task.sleep(for: .milliseconds(750)) } catch { return [] }
            }
        }
        return []
    }

    private enum Availability { case missing, ready, remote }

    /// 本机是否能直接读。非 iCloud 的普通文件（模拟器、测试）没有下载状态，按「有文件就能读」算
    private static func availability(of file: URL) -> Availability {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else {
            // 旧系统把没下载的文件显示成 `.名字.icloud` 占位，真名文件不存在
            let placeholder = file.deletingLastPathComponent()
                .appendingPathComponent("." + file.lastPathComponent + ".icloud")
            return manager.fileExists(atPath: placeholder.path) ? .remote : .missing
        }
        let status = try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        guard let status else { return .ready }
        return status == .current ? .ready : .remote
    }

    /// LRC 不带编码声明。中文歌词大量是 GB18030，按 UTF-8 硬读会整个失败、
    /// 一个字都出不来，所以依次试，第一个解得出的算数
    static func decode(_ data: Data) -> String {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for encoding in [.utf8, gb18030, .utf16] as [String.Encoding] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return ""
    }

    /// 手写解析而不用正则字面量：为一个解析器引入正则的编译与语言模式要求，代价比这几行大
    static func parse(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var offset: TimeInterval = 0

        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var stamps: [TimeInterval] = []
            // 行首能连着挂好几个 [..]（副歌复用同一句），逐个啃掉，
            // 第一个啃不动的地方就是歌词正文的起点
            while true {
                rest = rest.drop(while: \.isWhitespace)
                guard rest.hasPrefix("["), let close = rest.firstIndex(of: "]") else { break }
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let time = time(from: tag) {
                    stamps.append(time)
                } else if let value = offsetSeconds(from: tag) {
                    offset = value
                }
            }
            // 只要求有时间戳，不要求有词：`[00:10.00]` 这种空行是作者排的间奏留白，
            // 删掉会把呼吸感一并删掉
            guard !stamps.isEmpty else { continue }
            let body = rest.trimmingCharacters(in: .whitespaces)
            lines.append(contentsOf: stamps.map { LyricLine(time: $0, text: body) })
        }

        // offset 通常在文件头，但不保证——全部解析完再统一施加，出现在哪都认。
        // sorted 是稳定排序的话同一时刻的两句保持文件里的先后；Swift 的 sorted 并不保证稳定，
        // 所以带上原序号一起比
        return lines.enumerated()
            .map { (index: $0.offset, line: LyricLine(time: max(0, $0.element.time - offset), text: $0.element.text)) }
            .sorted { ($0.line.time, $0.index) < ($1.line.time, $1.index) }
            .map(\.line)
    }

    /// `00:12.34` / `00:12:34` / `00:12` → 秒。`ti`、`ar` 这类元信息标签返回 nil
    private static func time(from tag: Substring) -> TimeInterval? {
        let parts = tag.split(whereSeparator: { $0 == ":" || $0 == "." })
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let minute = TimeInterval(parts[0]), let second = TimeInterval(parts[1])
        else { return nil }
        var result = minute * 60 + second
        // 两位是厘秒、三位是毫秒，按位数除，不能写死 100
        if parts.count == 3, let fraction = TimeInterval(parts[2]) {
            result += fraction / pow(10, TimeInterval(parts[2].count))
        }
        return result
    }

    /// `offset:+500` → 0.5 秒
    private static func offsetSeconds(from tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, parts[0].lowercased() == "offset",
              let milliseconds = TimeInterval(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return milliseconds / 1000
    }

    /// 整体平移歌词时间。`seconds` 为正表示歌词提前出现（和 LRC 的 `[offset:+500]` 同一个方向），
    /// 为负表示延后。提前时最前面几句可能被推到 0 以下，夹在 0，不会出现负时间
    static func shifted(_ lines: [LyricLine], by seconds: TimeInterval) -> [LyricLine] {
        guard seconds != 0 else { return lines }
        return lines.map { LyricLine(time: max(0, $0.time - seconds), text: $0.text) }
    }

    /// 此刻该高亮第几行：最后一句已经到点的。还没唱到第一句时返回 nil
    static func index(at time: TimeInterval, in lines: [LyricLine]) -> Int? {
        // 二分：lines 已按时间排好，找第一个「还没到点」的位置再退一格
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }
}
