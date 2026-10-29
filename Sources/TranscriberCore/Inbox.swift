import Foundation
import UniformTypeIdentifiers

/// 能轉錄的檔案：音檔或影片（取影片的聲音）。App 的拖放、選檔與收件資料夾共用同一個判斷。
public enum SupportedMedia {
    public static let types: [UTType] = [.audio, .movie]

    public static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { type.conforms(to: $0) }
    }
}

/// iPhone 分享過來的音檔走 iCloud 雲碟：
///
///     iCloud 雲碟/Lisvo/
///     ├── 收件/     iPhone 的捷徑把音檔存到這裡
///     ├── 已處理/   轉完的音檔移到這裡，避免重複轉錄
///     └── 逐字稿/   轉好的逐字稿，iPhone 的「檔案」App 直接看得到
public struct InboxFolders: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var inbox: URL { root.appendingPathComponent("收件", isDirectory: true) }
    public var processed: URL { root.appendingPathComponent("已處理", isDirectory: true) }
    public var transcripts: URL { root.appendingPathComponent("逐字稿", isDirectory: true) }

    /// iCloud 雲碟在 Mac 上的位置。沒登入 iCloud 或沒開 iCloud 雲碟時這個資料夾不存在，回傳 nil。
    public static var iCloud: InboxFolders? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: drive.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return InboxFolders(root: drive.appendingPathComponent("Lisvo", isDirectory: true))
    }

    public func createIfNeeded() throws {
        for folder in [inbox, processed, transcripts] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// 轉完的音檔移到「已處理」。同名時加序號，不覆蓋舊檔。回傳移動後的位置。
    @discardableResult
    public func markProcessed(_ file: URL) throws -> URL {
        let destination = Self.uniqueDestination(for: file.lastPathComponent, in: processed)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    static func uniqueDestination(for fileName: String, in folder: URL) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            candidate = folder.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }
}

/// 找出收件資料夾裡「已經完整、可以開始轉」的音檔。
///
/// iCloud 同步過來的檔案可能還沒下載完，判斷方式：
/// - 還在雲端（沒下載到這台 Mac）的檔案，要求系統下載，這一輪先跳過。
/// - 已在本機的檔案，大小要連續兩次掃描都一樣才算寫完，避免拿到寫一半的檔案。
public struct InboxScanner {
    /// 上一次掃描看到的檔案大小。
    private var lastSizes: [URL: Int64] = [:]

    public init() {}

    /// 回傳可以處理的音檔，依加入時間由舊到新排序。
    public mutating func readyFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .creationDateKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: []
        )) ?? []

        var sizes: [URL: Int64] = [:]
        var ready: [(url: URL, created: Date)] = []
        for url in contents {
            let name = url.lastPathComponent
            // 舊式 iCloud 佔位檔：「.檔名.icloud」。要求下載真正的檔案，下載完它就會以原名出現。
            if let realName = Self.placeholderTarget(of: name) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(realName))
                continue
            }
            if name.hasPrefix(".") || !SupportedMedia.isSupported(url) { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }

            // 新式 iCloud（檔名不變、內容還在雲端）：要求下載，等下載完再處理。
            if values.isUbiquitousItem == true,
               let status = values.ubiquitousItemDownloadingStatus,
               status != .current {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }

            let size = Int64(values.fileSize ?? 0)
            sizes[url] = size
            if size > 0, lastSizes[url] == size {
                ready.append((url, values.creationDate ?? .distantPast))
            }
        }
        lastSizes = sizes
        return ready.sorted { $0.created < $1.created }.map(\.url)
    }

    /// 「.會議.m4a.icloud」→「會議.m4a」；不是佔位檔回傳 nil。
    static func placeholderTarget(of name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let real = String(name.dropFirst().dropLast(".icloud".count))
        return real.isEmpty ? nil : real
    }
}
