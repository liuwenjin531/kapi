import Foundation

/// 乐库里的文件操作：新建文件夹、导入、删除，以及整理（重命名、移动、拷贝、删文件夹）。
///
/// 所有写操作都走 `NSFileCoordinator`：iCloud 守护进程（bird）也在读写同一批文件，
/// 不协调的话可能在它上传到一半时覆盖或删掉文件。
/// 操作成功后发 `didChange`：本机乐库没有变化推送，靠它触发重扫；
/// iCloud 乐库由 `NSMetadataQuery` 自己推送，这条通知没人订阅，发了也无妨。
struct LibraryFiles: Sendable {
    /// 乐库里的文件被本 App 改过（新建文件夹 / 导入 / 删除）
    static let didChange = Notification.Name("LibraryFiles.didChange")

    /// 乐库根目录，即容器里的 `Documents/`
    let documentsURL: URL

    enum FileError: LocalizedError, Equatable {
        case invalidName
        case alreadyExists
        case invalidPath
        case unsupportedType
        /// 重命名的目标名已被占用（重命名不自动加后缀：用户想要的是这个名字，改成「X 2」反而意外）
        case nameTaken
        /// 把文件夹移动 / 拷贝进它自己或它的子孙里
        case intoItself
        /// 目标文件夹不存在（可能刚在别处被删）
        case destinationMissing

        var errorDescription: String? {
            switch self {
            case .invalidName: "名称不能为空，也不能含有「/」「:」或以「.」开头"
            case .alreadyExists: "已存在同名文件夹"
            case .invalidPath: "目标位置不在乐库里"
            case .unsupportedType: "不支持的文件类型"
            case .nameTaken: "已存在同名的文件或文件夹，请换一个名字"
            case .intoItself: "不能把文件夹移动或拷贝到它自己里面"
            case .destinationMissing: "目标文件夹不存在"
            }
        }
    }

    /// 一次导入的结果。界面据此提示「已导入 N 首」「M 个失败」
    struct ImportResult: Sendable {
        /// 成功拷进乐库的源文件
        var imported: [URL] = []
        /// 不是音视频（也不是歌词）而被跳过的源文件
        var skipped: [URL] = []
        /// 拷贝失败的源文件
        var failed: [URL] = []
    }

    // MARK: - 新建文件夹

    /// 在 `folderPath`（相对 `Documents/`，根目录为空串）下新建文件夹，返回新文件夹的相对路径
    @concurrent
    func createFolder(named name: String, in folderPath: String) async throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 「.」开头会被扫描当成隐藏项，建出来自己却看不见
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains(":"), !clean.hasPrefix(".") else {
            throw FileError.invalidName
        }
        let parent = try resolve(folderPath)
        let target = parent.appending(path: clean, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            throw FileError.alreadyExists
        }
        try Self.coordinatedWrite(at: target) { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        Self.notifyChange()
        return folderPath.isEmpty ? clean : folderPath + "/" + clean
    }

    // MARK: - 导入

    /// 把外部文件拷进 `folderPath`。重名不覆盖，自动加「 2」「 3」。
    /// 同名 `.lrc` 若在同一批里，会跟着歌一起改名，否则歌被改成「X 2.mp3」后歌词就对不上了。
    /// 来源可能是文件选择器 / 分享扩展 / 相册，前者给的是安全作用域 URL，要 start / stop。
    @concurrent
    func importFiles(_ urls: [URL], into folderPath: String) async throws -> ImportResult {
        let destination = try resolve(folderPath)
        let fm = FileManager.default
        // 目录可能刚被用户在「文件」App 里删掉，先确保它在
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var result = ImportResult()
        // 同一批里已占用的名字：iCloud 占位文件系统上 fileExists 不一定立刻反映刚拷进去的
        var taken = Set<String>()
        // 原文件名（不含扩展名，小写）→ 实际用的新名字，给 .lrc 对齐用
        var renamedStems: [String: String] = [:]

        // 先处理歌，再处理 .lrc，这样 .lrc 能查到歌的新名字
        let media = urls.filter { LibraryScan.isMedia($0.lastPathComponent) }
        let lyrics = urls.filter { $0.pathExtension.lowercased() == "lrc" }
        result.skipped = urls.filter { !media.contains($0) && !lyrics.contains($0) }

        for url in media {
            let name = Self.uniqueName(for: url.lastPathComponent, in: destination, taken: taken)
            taken.insert(name)
            renamedStems[(url.deletingPathExtension().lastPathComponent).lowercased()] =
                (name as NSString).deletingPathExtension
            if Self.copyIn(url, to: destination.appending(path: name)) {
                result.imported.append(url)
            } else {
                result.failed.append(url)
            }
        }
        for url in lyrics {
            let stem = url.deletingPathExtension().lastPathComponent
            let newStem = renamedStems[stem.lowercased()] ?? stem
            // 同名歌词已在目标里就加后缀，不覆盖
            let wanted = newStem + ".lrc"
            let name = renamedStems[stem.lowercased()] != nil
                ? wanted
                : Self.uniqueName(for: wanted, in: destination, taken: taken)
            taken.insert(name)
            if Self.copyIn(url, to: destination.appending(path: name)) {
                result.imported.append(url)
            } else {
                result.failed.append(url)
            }
        }
        if !result.imported.isEmpty { Self.notifyChange() }
        return result
    }

    // MARK: - 删除

    /// 删一首歌，连同同名 `.lrc`。歌词是跟着歌走的附属文件，不一起删就成了孤儿——
    /// 乐库只列媒体文件，用户看不见它，也就永远删不掉
    @concurrent
    func delete(_ track: Track) async throws {
        let song = try resolve(track.path)
        let lyric = song.deletingPathExtension().appendingPathExtension("lrc")
        try Self.coordinatedWrite(at: song, options: .forDeleting) { url in
            try FileManager.default.removeItem(at: url)
        }
        if FileManager.default.fileExists(atPath: lyric.path(percentEncoded: false)) {
            try Self.coordinatedWrite(at: lyric, options: .forDeleting) { url in
                try FileManager.default.removeItem(at: url)
            }
        }
        Self.notifyChange()
    }

    // MARK: - 内部

    fileprivate static func notifyChange() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 相对路径 → 容器里的绝对 URL，并确保没有跳出 `Documents/`
    fileprivate func resolve(_ relative: String) throws -> URL {
        guard Self.isSafe(relative) else { throw FileError.invalidPath }
        return relative.isEmpty ? documentsURL : documentsURL.appending(path: relative)
    }

    /// 不允许绝对路径和 `..`：路径来自界面和歌单数据，数据被改坏时不能借此写到容器外
    static func isSafe(_ relative: String) -> Bool {
        !relative.hasPrefix("/") && !relative.split(separator: "/").contains("..")
    }

    /// 重名加后缀：`歌.mp3` → `歌 2.mp3` → `歌 3.mp3`。
    /// 也避开 iCloud 老式占位名 `.歌.mp3.icloud`，那说明云上有同名文件、只是还没下载
    /// `isDirectory` 为 true 时整个名字都当主体：文件夹「Vol.1」不能被当成「Vol」+ 扩展名「1」
    static func uniqueName(for fileName: String, in directory: URL, taken: Set<String>,
                           isDirectory: Bool = false) -> String {
        let fm = FileManager.default
        func isFree(_ name: String) -> Bool {
            !taken.contains(name)
                && !fm.fileExists(atPath: directory.appending(path: name).path(percentEncoded: false))
                && !fm.fileExists(atPath: directory.appending(path: "." + name + ".icloud").path(percentEncoded: false))
        }
        if isFree(fileName) { return fileName }
        let stem = isDirectory ? fileName : (fileName as NSString).deletingPathExtension
        let ext = isDirectory ? "" : (fileName as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if isFree(candidate) { return candidate }
            n += 1
        }
    }

    /// 拷一个文件进来。读源和写目标一起协调，源可能是别的 App 的文件或选择器给的安全作用域 URL
    private static func copyIn(_ source: URL, to destination: URL) -> Bool {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source, options: .withoutChanges,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { readURL, writeURL in
            do { try FileManager.default.copyItem(at: readURL, to: writeURL) } catch { copyError = error }
        }
        return coordinationError == nil && copyError == nil
    }

    fileprivate static func coordinatedWrite(
        at url: URL,
        options: NSFileCoordinator.WritingOptions = [],
        _ body: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: options, error: &coordinationError
        ) { coordinated in
            do { try body(coordinated) } catch { bodyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let bodyError { throw bodyError }
    }
}

// MARK: - 整理：重命名、移动、拷贝、删除文件夹

/// 一次批量操作的结果。批量时某一项失败不影响其他项，失败的在 `failures` 里列出来给界面提示
struct OrganizeResult: Sendable {
    /// 成功的路径变化（移动、重命名才有；拷贝和删除为空）
    var changes: [PathChange] = []
    /// 成功处理的项数
    var succeeded = 0
    /// 因为本来就在目标位置而跳过的项数
    var skipped = 0
    /// 失败说明，每项一行：「名称：原因」
    var failures: [String] = []
}

extension LibraryFiles {
    /// 名称校验，规则同新建文件夹：不能空、不能含 / :、不能以 . 开头（会被扫描当隐藏项）。返回去掉首尾空白的名字
    static func cleanName(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains(":"), !clean.hasPrefix(".") else {
            throw FileError.invalidName
        }
        return clean
    }

    /// 歌词文件：同目录、同文件名、扩展名换成 lrc
    static func lyricURL(for song: URL) -> URL {
        song.deletingPathExtension().appendingPathExtension("lrc")
    }

    // MARK: 重命名

    /// 重命名一首歌，只改文件名主体，保留原扩展名；同名 `.lrc` 一起改。
    /// 目标名已被占用就抛 `nameTaken`。只改了大小写（`a.mp3` → `A.mp3`）算改名，不算冲突。
    /// 名字没变时 `skipped` 为 1、没有 `changes`；歌改成功但歌词没跟上时，歌词的问题记在 `failures` 里
    @concurrent
    func renameSong(_ track: Track, to newStem: String) async throws -> OrganizeResult {
        let stem = try Self.cleanName(newStem)
        let song = try resolve(track.path)
        let ext = song.pathExtension
        let newName = ext.isEmpty ? stem : stem + "." + ext
        guard newName != song.lastPathComponent else { return OrganizeResult(skipped: 1) }

        let dir = song.deletingLastPathComponent()
        let target = dir.appending(path: newName)
        let lyric = Self.lyricURL(for: song)
        let hasLyric = FileManager.default.fileExists(atPath: lyric.path(percentEncoded: false))
        let lyricTarget = Self.lyricURL(for: target)
        guard !Self.isOccupied(target, renaming: song),
              !(hasLyric && Self.isOccupied(lyricTarget, renaming: lyric)) else {
            throw FileError.nameTaken
        }

        try Self.coordinatedMove(from: song, to: target)
        var result = OrganizeResult(succeeded: 1)
        let folder = track.folderPath
        result.changes = [PathChange(old: track.path, new: folder.isEmpty ? newName : folder + "/" + newName,
                                     isFolder: false)]
        if hasLyric {
            // 歌已经改成功了，歌词没跟上也不回滚歌：路径变化照常返回，歌词的问题交给界面提示
            do {
                try Self.coordinatedMove(from: lyric, to: lyricTarget)
            } catch {
                result.failures.append("\(lyric.lastPathComponent)（歌词）：\(error.localizedDescription)")
            }
        }
        Self.notifyChange()
        return result
    }

    /// 重命名文件夹。根目录不能改名；目标名被占用抛 `nameTaken`；名字没变时 `skipped` 为 1
    @concurrent
    func renameFolder(_ path: String, to newName: String) async throws -> OrganizeResult {
        let name = try Self.cleanName(newName)
        guard !path.isEmpty else { throw FileError.invalidPath }
        let source = try resolve(path)
        guard name != source.lastPathComponent else { return OrganizeResult(skipped: 1) }
        let target = source.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
        guard !Self.isOccupied(target, renaming: source) else { throw FileError.nameTaken }

        try Self.coordinatedMove(from: source, to: target)
        Self.notifyChange()
        let parent = (path as NSString).deletingLastPathComponent
        return OrganizeResult(
            changes: [PathChange(old: path, new: parent.isEmpty ? name : parent + "/" + name, isFolder: true)],
            succeeded: 1)
    }

    // MARK: 移动 / 拷贝

    /// 把歌和文件夹移动到 `destination`（相对路径，根目录为空串）。
    /// 目标已有同名：不覆盖，加「 2」「 3」；歌词跟着歌走；本来就在目标里的跳过；
    /// 任何一个文件夹要移进它自己或子孙里，整批都不做（抛 `intoItself`）
    @concurrent
    func move(songs: [Track], folders: [String], to destination: String) async throws -> OrganizeResult {
        try await transfer(songs: songs, folders: folders, to: destination, copying: false)
    }

    /// 拷贝，规则同移动（但拷到原来所在的文件夹也会做，得到「X 2」副本）。
    /// 副本是新文件，不进原歌单、不带歌词微调
    @concurrent
    func copy(songs: [Track], folders: [String], to destination: String) async throws -> OrganizeResult {
        try await transfer(songs: songs, folders: folders, to: destination, copying: true)
    }

    private func transfer(songs: [Track], folders: [String], to destination: String,
                          copying: Bool) async throws -> OrganizeResult {
        let destURL = try resolve(destination)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destURL.path(percentEncoded: false), isDirectory: &isDir),
              isDir.boolValue else { throw FileError.destinationMissing }
        for folder in folders {
            guard Self.isSafe(folder) else { throw FileError.invalidPath }
            if Self.isInside(destination, of: folder) { throw FileError.intoItself }
        }

        var result = OrganizeResult()
        var taken = Set<String>()
        for folder in folders {
            let name = (folder as NSString).lastPathComponent
            let parent = (folder as NSString).deletingLastPathComponent
            if !copying, parent == destination { result.skipped += 1; continue }
            do {
                let source = try resolve(folder)
                let newName = Self.uniqueName(for: name, in: destURL, taken: taken, isDirectory: true)
                taken.insert(newName)
                let target = destURL.appending(path: newName, directoryHint: .isDirectory)
                if copying {
                    try Self.coordinatedCopy(from: source, to: target)
                } else {
                    try Self.coordinatedMove(from: source, to: target)
                    result.changes.append(PathChange(
                        old: folder, new: destination.isEmpty ? newName : destination + "/" + newName, isFolder: true))
                }
                result.succeeded += 1
            } catch {
                result.failures.append("\(name)：\(error.localizedDescription)")
            }
        }
        for track in songs {
            if !copying, track.folderPath == destination { result.skipped += 1; continue }
            do {
                let source = try resolve(track.path)
                let lyric = Self.lyricURL(for: source)
                let hasLyric = FileManager.default.fileExists(atPath: lyric.path(percentEncoded: false))
                let newName = Self.uniqueSongName(for: source.lastPathComponent, in: destURL,
                                                  taken: taken, hasLyric: hasLyric)
                taken.insert(newName)
                let newLyric = (newName as NSString).deletingPathExtension + ".lrc"
                taken.insert(newLyric)
                let target = destURL.appending(path: newName)
                if copying {
                    try Self.coordinatedCopy(from: source, to: target)
                } else {
                    try Self.coordinatedMove(from: source, to: target)
                    result.changes.append(PathChange(
                        old: track.path, new: destination.isEmpty ? newName : destination + "/" + newName, isFolder: false))
                }
                result.succeeded += 1
                if hasLyric {
                    let lyricTarget = destURL.appending(path: newLyric)
                    do {
                        if copying {
                            try Self.coordinatedCopy(from: lyric, to: lyricTarget)
                        } else {
                            try Self.coordinatedMove(from: lyric, to: lyricTarget)
                        }
                    } catch {
                        result.failures.append("\(newLyric)（歌词）：\(error.localizedDescription)")
                    }
                }
            } catch {
                result.failures.append("\(track.fileName)：\(error.localizedDescription)")
            }
        }
        if result.succeeded > 0 { Self.notifyChange() }
        return result
    }

    // MARK: 删除

    /// 删一个文件夹，连同里面的所有内容
    @concurrent
    func deleteFolder(_ path: String) async throws {
        guard !path.isEmpty else { throw FileError.invalidPath }
        let folder = try resolve(path)
        try Self.coordinatedWrite(at: folder, options: .forDeleting) { url in
            try FileManager.default.removeItem(at: url)
        }
        Self.notifyChange()
    }

    /// 批量删除歌（连歌词）和文件夹（连内容）。某一项失败不影响其他项
    @concurrent
    func delete(songs: [Track], folders: [String]) async -> OrganizeResult {
        var result = OrganizeResult()
        for folder in folders {
            do {
                try await deleteFolder(folder)
                result.succeeded += 1
            } catch {
                result.failures.append("\((folder as NSString).lastPathComponent)：\(error.localizedDescription)")
            }
        }
        for track in songs {
            do {
                try await delete(track)
                result.succeeded += 1
            } catch {
                result.failures.append("\(track.fileName)：\(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: 内部

    /// `path` 是不是 `folder` 本身或它的子孙（相对路径；`folder` 为空串表示根目录，什么都在它里面，但根目录不会被移动）
    static func isInside(_ path: String, of folder: String) -> Bool {
        !folder.isEmpty && (path == folder || path.hasPrefix(folder + "/"))
    }

    /// 目标位置是否被别的东西占着（也算 iCloud 老式占位名）。`renaming` 是被改名的那一项自己：
    /// 只改大小写时，大小写不敏感的文件系统会说目标「已存在」，其实就是它自己
    private static func isOccupied(_ target: URL, renaming source: URL) -> Bool {
        let fm = FileManager.default
        if target.lastPathComponent.lowercased() == source.lastPathComponent.lowercased(),
           target.deletingLastPathComponent().path == source.deletingLastPathComponent().path {
            return false
        }
        let placeholder = target.deletingLastPathComponent()
            .appending(path: "." + target.lastPathComponent + ".icloud")
        return fm.fileExists(atPath: target.path(percentEncoded: false))
            || fm.fileExists(atPath: placeholder.path(percentEncoded: false))
    }

    /// 给歌挑目标名：除了歌本身不重名，带歌词时同名 `.lrc` 也不能被目标里的孤儿歌词占着，
    /// 否则歌和歌词对不上
    static func uniqueSongName(for fileName: String, in directory: URL, taken: Set<String>, hasLyric: Bool) -> String {
        var blocked = taken
        while true {
            let candidate = uniqueName(for: fileName, in: directory, taken: blocked)
            guard hasLyric else { return candidate }
            let lyricName = (candidate as NSString).deletingPathExtension + ".lrc"
            let lyricFree = !taken.contains(lyricName)
                && !FileManager.default.fileExists(atPath: directory.appending(path: lyricName).path(percentEncoded: false))
            if lyricFree { return candidate }
            blocked.insert(candidate)
        }
    }

    /// 协调的移动 / 改名：源按「移动」、目标按「替换」申请，iCloud 守护进程才知道这是一次搬家而不是删一个再建一个
    private static func coordinatedMove(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            do { try FileManager.default.moveItem(at: from, to: to) } catch { moveError = error }
        }
        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
    }

    /// 协调的拷贝。源还在云上没下载时，协调读会触发下载，拷完才返回
    private static func coordinatedCopy(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source, options: .withoutChanges,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            do { try FileManager.default.copyItem(at: from, to: to) } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }
}
