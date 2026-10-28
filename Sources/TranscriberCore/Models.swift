import Foundation

/// 一個帶時間的字詞或片語。Apple 辨識給的是片語，Whisper 給的是字詞或單一漢字。
public struct TimedWord: Codable, Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// 逐字稿裡的一句話。
public struct TranscriptSegment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    /// 顯示用的講者名稱，例如「講者 1」。分講者還沒完成或沒開時是 nil。
    public var speaker: String?
    public var words: [TimedWord]

    public init(id: UUID = UUID(), start: Double, end: Double, text: String, speaker: String? = nil, words: [TimedWord] = []) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.words = words
    }
}

/// 分講者模型找出來的一段「某人在這段時間說話」。
public struct SpeakerTurn: Codable, Sendable, Hashable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

public enum EngineKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Mac 內建語音辨識（SpeechTranscriber）。
    case fast
    /// WhisperKit（Whisper large-v3-turbo）。
    case accurate

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fast: "快速"
        case .accurate: "精準"
        }
    }
}

/// 使用者選的語言。快速模式需要明確的地區語言；精準模式可以自動偵測。
public enum TranscriptionLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case zhTW
    case yue
    case en
    case ja
    case ko

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: "自動偵測"
        case .zhTW: "中文（台灣）"
        case .yue: "粵語"
        case .en: "英文"
        case .ja: "日文"
        case .ko: "韓文"
        }
    }

    /// 快速模式用的地區語言。自動偵測時沒有對應值，快速模式不能用。
    public var appleLocaleIdentifier: String? {
        switch self {
        case .auto: nil
        case .zhTW: "zh-TW"
        case .yue: "yue-CN"
        case .en: "en-US"
        case .ja: "ja-JP"
        case .ko: "ko-KR"
        }
    }

    /// Whisper 的語言代碼。nil 代表交給模型自動偵測。
    public var whisperCode: String? {
        switch self {
        case .auto: nil
        case .zhTW: "zh"
        case .yue: "yue"
        case .en: "en"
        case .ja: "ja"
        case .ko: "ko"
        }
    }

    /// Whisper 中文常輸出簡體字，選了繁體中文時要再轉一次。
    public var wantsTraditionalChinese: Bool {
        self == .zhTW || self == .yue
    }
}

/// 一次轉錄的完整結果，匯出 JSON 時就是這個結構。
public struct Transcript: Codable, Sendable {
    public var sourceFileName: String
    public var engine: EngineKind
    public var language: TranscriptionLanguage
    public var detectedLanguage: String?
    public var audioDuration: Double
    public var processingSeconds: Double
    public var speakerDetection: Bool
    public var segments: [TranscriptSegment]
    /// AI 潤飾後的版本，以講者段落為單位；沒開潤飾時是 nil。
    public var polished: [PolishedParagraph]?

    public init(
        sourceFileName: String,
        engine: EngineKind,
        language: TranscriptionLanguage,
        detectedLanguage: String?,
        audioDuration: Double,
        processingSeconds: Double,
        speakerDetection: Bool,
        segments: [TranscriptSegment],
        polished: [PolishedParagraph]? = nil
    ) {
        self.sourceFileName = sourceFileName
        self.engine = engine
        self.language = language
        self.detectedLanguage = detectedLanguage
        self.audioDuration = audioDuration
        self.processingSeconds = processingSeconds
        self.speakerDetection = speakerDetection
        self.segments = segments
        self.polished = polished
    }
}

/// 潤飾的單位：同一位講者連續說的一段話。原文和潤飾後的文字都保留。
public struct PolishedParagraph: Codable, Sendable, Hashable {
    public var start: Double
    public var end: Double
    public var speaker: String?
    public var original: String
    public var polished: String
    /// 模型失敗或輸出不合理時為 false，此時 polished 等於 original。
    public var didPolish: Bool

    public init(start: Double, end: Double, speaker: String?, original: String, polished: String, didPolish: Bool) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.original = original
        self.polished = polished
        self.didPolish = didPolish
    }
}
