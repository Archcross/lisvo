import Foundation
import Translation

/// 即時字幕可以翻成的語言。
public enum TranslationTarget: String, CaseIterable, Identifiable, Sendable {
    case off
    case zhHant
    case en
    case ja
    case ko
    /// 中英夾雜：中文的段落翻成英文、英文的段落翻成繁體中文，同時跑中文和英文兩個辨識器。
    case bilingual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "不翻譯"
        case .zhHant: "繁體中文"
        case .en: "英文"
        case .ja: "日文"
        case .ko: "韓文"
        case .bilingual: "中英互譯"
        }
    }

    /// 固定翻成的語言。中英互譯每段的方向不同，是 nil（見 `resolved(for:)`）。
    public var language: Locale.Language? {
        switch self {
        case .zhHant: Locale.Language(identifier: "zh-Hant")
        case .en: Locale.Language(identifier: "en")
        case .ja: Locale.Language(identifier: "ja")
        case .ko: Locale.Language(identifier: "ko")
        case .off, .bilingual: nil
        }
    }

    /// 要不要同時跑英文辨識器。中文辨識器會把整句英文聽成亂碼，互譯時要靠英文辨識器補上。
    public var needsEnglishRecognition: Bool { self == .bilingual }

    /// 這段原文要翻成哪種語言：中英互譯時中文翻英文、其餘翻繁體中文，其他選項就是自己。
    public func resolved(for text: String) -> TranslationTarget {
        guard self == .bilingual else { return self }
        return BilingualText.isChinese(text) ? .en : .zhHant
    }

    /// 「聽」選這個語言時，選單裡有沒有這個翻譯選項。
    /// 中英互譯以中文辨識結果為主（見 BilingualMerge），只在聽中文（台灣）時提供。
    public func isAvailable(listening source: TranscriptionLanguage) -> Bool {
        switch self {
        case .off: true
        case .bilingual: source == .zhTW
        default: !source.isSameLanguage(as: self)
        }
    }

    /// 這次字幕要準備的翻譯方向：譯文語言 → 原文語言。中英互譯有兩個方向。
    public func directions(listening source: TranscriptionLanguage) -> [TranslationTarget: Locale.Language] {
        guard isAvailable(listening: source) else { return [:] }
        switch self {
        case .off:
            return [:]
        case .bilingual:
            return [.en: Locale.Language(identifier: "zh-Hant"), .zhHant: Locale.Language(identifier: "en")]
        default:
            guard let from = source.translationSource else { return [:] }
            return [self: from]
        }
    }

    /// 把幾段譯文接起來：中日文之間不加空格，有英文或韓文的一側加空格。
    /// 中英互譯時同一行會同時有中文和英文譯文，所以看接縫兩邊的字決定。
    public func join(_ parts: [String]) -> String {
        let parts = parts.filter { !$0.isEmpty }
        switch self {
        case .zhHant, .ja: return parts.joined()
        case .off, .en, .ko: return parts.joined(separator: " ")
        case .bilingual:
            var result = ""
            for part in parts {
                if let last = result.last, let first = part.first,
                   !(Self.isWideCharacter(last) && Self.isWideCharacter(first)) {
                    result += " "
                }
                result += part
            }
            return result
        }
    }

    /// 中日文字或全形標點：兩側都是這種字時不加空格。
    private static func isWideCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isIdeographic
                || (0x3000...0x30FF).contains(scalar.value)   // 中日文標點、假名
                || (0xFF00...0xFFEF).contains(scalar.value)   // 全形標點
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

    /// 字詞之間用空格分開的語言（英文、韓文）用字數算長度，中日文用字元數。
    public var separatesWordsWithSpaces: Bool {
        switch self {
        case .en, .ko: true
        case .auto, .zhTW, .yue, .ja: false
        }
    }

    /// 來源和翻譯目標是同一種語言時不用翻。中英互譯沒有固定的目標語言，不算相同。
    public func isSameLanguage(as target: TranslationTarget) -> Bool {
        guard let source = translationSource, let destination = target.language else { return false }
        return source.languageCode == destination.languageCode
    }
}

/// 把字幕文字切成一段一段。遇到切點標點的才算「講完的一段」，最後沒講完的部分另外回傳。
/// - `.sentence`：句尾標點（。！？；…），存檔的譯文用這個，前後文完整、翻得比較準。
/// - `.clause`：再加上逗號、冒號，即時字幕用這個，譯文才跟得上說話速度。
///   頓號（、）不算：它用在列舉（「蘋果、香蕉」），切開只會翻出單字。
public enum SentenceSplitter {
    public enum Boundary: Sendable {
        case sentence
        case clause
    }

    private static let terminators: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "…"]
    /// 一定是切點的全形逗號、冒號。
    private static let clauseMarks: Set<Character> = ["，", "："]
    /// 半形逗號、冒號：後面接空白或結尾才算，「1,000」「10:30」中間的不算。
    private static let spacedClauseMarks: Set<Character> = [",", ":"]
    /// 緊跟在切點標點後面、屬於同一段的收尾符號。
    private static let closers: Set<Character> = ["」", "』", "”", "’", "\"", "'", "）", ")"]

    public static func split(_ text: String, at boundary: Boundary = .sentence) -> (complete: [String], remainder: String) {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            if isSentenceEnd(at: index, in: characters) || (boundary == .clause && isClauseEnd(at: index, in: characters)) {
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

    private static func isClauseEnd(at index: Int, in characters: [Character]) -> Bool {
        let character = characters[index]
        if clauseMarks.contains(character) { return true }
        guard spacedClauseMarks.contains(character) else { return false }
        return index + 1 >= characters.count || characters[index + 1].isWhitespace
    }

    private static func append(_ sentence: String, to sentences: inout [String]) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只有標點、沒有內容的不算一句。
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        sentences.append(trimmed)
    }
}

/// 即時翻譯什麼時候翻「還沒遇到標點」的部分。
/// Apple 即時辨識常常一長串都不加標點（實測「請工程團隊先做效能優化預算的部分我再跟財務確認」整段沒有逗號），
/// 只等標點的話，譯文會落後十幾秒。夠長時先暫時翻一次，之後遇到標點再換成那一段的正式譯文。
public enum UnfinishedTranslationPolicy {
    /// 中日文至少幾個字。約 2～3 秒的話，太短翻不出意思。
    public static let minimumCharacters = 12
    /// 英韓文至少幾個字（以空格分開的字）。
    public static let minimumWords = 8
    /// 同一段還沒講完的話，最快多久重翻一次。每次重翻譯文都會變，太頻繁會讓字幕一直跳。
    public static let minimumInterval: TimeInterval = 1

    public static func isLongEnough(_ text: String, language: TranscriptionLanguage) -> Bool {
        if language.separatesWordsWithSpaces {
            return text.split(whereSeparator: \.isWhitespace).count >= minimumWords
        }
        return text.filter { $0.isLetter || $0.isNumber }.count >= minimumCharacters
    }
}

public enum LiveTranslatorError: LocalizedError {
    case unsupported
    case sameLanguage
    case bilingualNeedsChinese

    public var errorDescription: String? {
        switch self {
        case .unsupported: "這組語言 Mac 內建翻譯不支援。"
        case .sameLanguage: "辨識語言和翻譯語言相同，不需要翻譯。"
        case .bilingualNeedsChinese: "中英互譯要在「聽」選中文（台灣）時使用。"
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
        return target.join(parts.compactMap { $0 })
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
