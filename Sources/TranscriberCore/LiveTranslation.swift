import Foundation
import Translation

/// 即時字幕可以翻成的語言。
public enum TranslationTarget: String, CaseIterable, Identifiable, Sendable {
    case off
    case zhHant
    case en
    case ja
    case ko

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "不翻譯"
        case .zhHant: "繁體中文"
        case .en: "英文"
        case .ja: "日文"
        case .ko: "韓文"
        }
    }

    public var language: Locale.Language? {
        switch self {
        case .off: nil
        case .zhHant: Locale.Language(identifier: "zh-Hant")
        case .en: Locale.Language(identifier: "en")
        case .ja: Locale.Language(identifier: "ja")
        case .ko: Locale.Language(identifier: "ko")
        }
    }

    /// 譯文句子之間要不要加空格：中日文不加，英韓文加。
    public var sentenceJoiner: String {
        switch self {
        case .zhHant, .ja: ""
        case .off, .en, .ko: " "
        }
    }
}

extension TranscriptionLanguage {
    /// 翻譯時的來源語言。粵語的辨識結果是繁體中文書面字，用繁體中文當來源。
    public var translationSource: Locale.Language? {
        switch self {
        case .auto: nil
        case .zhTW, .yue: Locale.Language(identifier: "zh-Hant")
        case .en: Locale.Language(identifier: "en")
        case .ja: Locale.Language(identifier: "ja")
        case .ko: Locale.Language(identifier: "ko")
        }
    }

    /// 來源和翻譯目標是同一種語言時不用翻。
    public func isSameLanguage(as target: TranslationTarget) -> Bool {
        guard let source = translationSource, let destination = target.language else { return false }
        return source.languageCode == destination.languageCode
    }
}

/// 把字幕文字切成句子。只有遇到句尾標點的才算「講完的一句」，最後沒講完的半句另外回傳。
/// 即時翻譯只翻講完的句子，半句不翻，譯文才不會一直跳動。
public enum SentenceSplitter {
    private static let terminators: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "…"]
    /// 緊跟在句尾標點後面、屬於同一句的收尾符號。
    private static let closers: Set<Character> = ["」", "』", "”", "’", "\"", "'", "）", ")"]

    public static func split(_ text: String) -> (complete: [String], remainder: String) {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            if isSentenceEnd(at: index, in: characters) {
                // 把緊接著的收尾符號一起帶走。
                while index + 1 < characters.count, closers.contains(characters[index + 1]) {
                    index += 1
                    current.append(characters[index])
                }
                append(current, to: &sentences)
                current = ""
            }
            index += 1
        }
        return (sentences, current.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 一段已定案的文字全部算完整句：最後沒有句號的半句也算一句。
    public static func allSentences(_ text: String) -> [String] {
        let (complete, remainder) = split(text)
        return remainder.isEmpty ? complete : complete + [remainder]
    }

    private static func isSentenceEnd(at index: Int, in characters: [Character]) -> Bool {
        let character = characters[index]
        if terminators.contains(character) { return true }
        // 英文句點：後面是空白或結尾、前面是字母才算句尾；「3.2」「U.S.」中間的點不算。
        guard character == "." else { return false }
        let nextIsBoundary = index + 1 >= characters.count || characters[index + 1].isWhitespace
        let previousIsLetter = index > 0 && characters[index - 1].isLetter
        let previousIsAbbreviation = index > 1 && characters[index - 2] == "."
        return nextIsBoundary && previousIsLetter && !previousIsAbbreviation
    }

    private static func append(_ sentence: String, to sentences: inout [String]) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只有標點、沒有內容的不算一句。
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        sentences.append(trimmed)
    }
}

public enum LiveTranslatorError: LocalizedError {
    case unsupported
    case sameLanguage

    public var errorDescription: String? {
        switch self {
        case .unsupported: "這組語言 Mac 內建翻譯不支援。"
        case .sameLanguage: "辨識語言和翻譯語言相同，不需要翻譯。"
        }
    }
}

/// 用 Mac 內建的翻譯（Translation 框架，「翻譯」App 用的同一套）在本機翻譯，不上網。
///
/// TranslationSession 不是 Sendable。這個類別由 App 裡唯一一條翻譯工作依序呼叫，
/// 同一時間只有一個 translate 在跑，所以手動標成 @unchecked Sendable。
public final class LiveTranslator: @unchecked Sendable {
    private let session: TranslationSession

    /// 語言包狀態：已安裝、可下載、不支援。
    public static func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    /// 只能在語言包已安裝時建立；還沒下載時要先用 SwiftUI 的 translationTask 讓使用者下載。
    public init(source: Locale.Language, target: Locale.Language) {
        if #available(macOS 26.4, *) {
            // 字幕要跟得上說話速度，選低延遲模式。
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
    }

    public func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }

    /// 讓系統跳出語言包下載提示。session 來自 SwiftUI 的 translationTask。
    /// 那個 session 不是 Sendable，包一層再交給這個非主執行緒的函式；它只在這裡用一次。
    public static func prepareDownload(_ box: SessionBox) async {
        try? await box.session.prepareTranslation()
    }

    public struct SessionBox: @unchecked Sendable {
        let session: TranslationSession
        public init(_ session: TranslationSession) { self.session = session }
    }
}

/// 即時字幕停止時，把譯文存成「即時字幕_翻譯.txt」：每段一行，前面是開始時間。
public enum LiveTranslationExport {
    /// 某段已定案文字的完整譯文；還有句子沒翻好時回傳 nil。
    public static func translation(of segment: TranscriptSegment, cache: [String: String], target: TranslationTarget) -> String? {
        let parts = SentenceSplitter.allSentences(segment.text).map { cache[$0] }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: target.sentenceJoiner)
    }

    public static func text(segments: [TranscriptSegment], cache: [String: String], target: TranslationTarget) -> String {
        segments.map { segment in
            let translated: String
            switch translation(of: segment, cache: cache, target: target) {
            case nil: translated = "（未翻譯）"
            case let text? where text.isEmpty: translated = "（翻譯失敗）"
            case let text?: translated = text
            }
            return "[\(Exporter.clock(segment.start))] \(translated)"
        }
        .joined(separator: "\n") + "\n"
    }
}
