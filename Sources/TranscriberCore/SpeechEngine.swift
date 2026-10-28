import Foundation

/// 辨識過程中送給畫面的即時事件。
public enum EngineEvent: Sendable {
    case status(String)
    /// 0...1
    case progress(Double)
    /// 新辨識出來的句子。精準模式會分段平行處理，所以句子不一定照時間順序到達。
    case segments([TranscriptSegment])
}

public struct EngineResult: Sendable {
    public var segments: [TranscriptSegment]
    public var detectedLanguage: String?

    public init(segments: [TranscriptSegment], detectedLanguage: String?) {
        self.segments = segments
        self.detectedLanguage = detectedLanguage
    }
}

public protocol SpeechEngine: Sendable {
    /// true 代表這個引擎要先拿到分講者結果，再按講者段落分別轉錄（回傳的句子已帶講者）。
    /// false 代表先轉錄整個檔案，之後再用時間重疊對講者。
    var transcribesPerSpeakerTurn: Bool { get }

    /// - Parameters:
    ///   - audio: 已經轉成 16 kHz 單聲道的 WAV。
    ///   - speakerTurns: transcribesPerSpeakerTurn 為 true 且有開分講者時才會給。
    func transcribe(
        audio: URL,
        duration: Double,
        language: TranscriptionLanguage,
        speakerTurns: [SpeakerTurn]?,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async throws -> EngineResult
}

enum TextCleanup {
    /// 中文標點與中文字之間不該有空格。Apple 辨識會在「，」前面插空格，
    /// 句子在換講者處切開後頭尾也可能留下空格。英文單字之間的空格保留。
    static func tidy(_ text: String, chinese: Bool) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if chinese { result = fullWidthPunctuation(result) }
        // 全形標點兩側的空白
        result = result.replacingOccurrences(
            of: #"\s*([，。？！：；、「」『』（）《》〈〉…—])\s*"#,
            with: "$1",
            options: .regularExpression
        )
        // 兩個中日韓字元之間的空白
        result = result.replacingOccurrences(
            of: #"(?<=[\p{Han}\p{Hiragana}\p{Katakana}])\s+(?=[\p{Han}\p{Hiragana}\p{Katakana}])"#,
            with: "",
            options: .regularExpression
        )
        return result
    }

    /// Whisper 中文常用半形「,?!:;」。緊鄰中文字的半形標點換成全形；
    /// 句點只在前面是中文字時才換，避免動到「3.2」這類數字。
    static func fullWidthPunctuation(_ text: String) -> String {
        let pairs: [(String, String)] = [(",", "，"), ("?", "？"), ("!", "！"), (":", "："), (";", "；")]
        var result = text
        for (half, full) in pairs {
            let escaped = NSRegularExpression.escapedPattern(for: half)
            result = result.replacingOccurrences(
                of: #"(?<=\p{Han})\s*"# + escaped + #"\s*|\s*"# + escaped + #"\s*(?=\p{Han})"#,
                with: full,
                options: .regularExpression
            )
        }
        result = result.replacingOccurrences(of: #"(?<=\p{Han})\.(?!\d)"#, with: "。", options: .regularExpression)
        return result
    }

    /// 這段逐字稿要不要用中文的排版規則（全形標點、字與字之間不留空格）。
    static func isChinese(language: TranscriptionLanguage, detectedLanguage: String?) -> Bool {
        if language.wantsTraditionalChinese { return true }
        if language != .auto { return false }
        return ["zh", "yue"].contains { (detectedLanguage ?? "").hasPrefix($0) }
    }

    /// 選繁體中文時，把 Whisper 偶爾輸出的簡體字轉成繁體。只轉字形，不轉用語（「軟件」不會變「軟體」）。
    static func toTraditional(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }
}
