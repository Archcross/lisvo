import AVFoundation
import Foundation
import Speech

public enum AppleSpeechEngineError: LocalizedError {
    case languageRequired
    case unsupportedLanguage(String)
    case notAuthorized

    public var errorDescription: String? {
        switch self {
        case .languageRequired:
            "快速模式不能自動偵測語言，請選一種語言。"
        case .unsupportedLanguage(let id):
            "這台 Mac 的內建語音辨識不支援 \(id)。"
        case .notAuthorized:
            "沒有語音辨識權限。請到「系統設定 → 隱私權與安全性 → 語音辨識」允許這個 App。"
        }
    }
}

/// 快速模式：Mac 內建的 SpeechTranscriber，跑在本機，不用另外下載模型（語言包由系統管理）。
public struct AppleSpeechEngine: SpeechEngine {
    public init() {}

    /// Apple 辨識的片語時間準確，先轉整個檔案再用時間對講者即可，文字也能最早出現。
    public var transcribesPerSpeakerTurn: Bool { false }

    public func transcribe(
        audio: URL,
        duration: Double,
        language: TranscriptionLanguage,
        speakerTurns: [SpeakerTurn]?,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async throws -> EngineResult {
        let (transcriber, locale) = try await Self.makeTranscriber(
            language: language,
            reportingOptions: [],
            onStatus: { onEvent(.status($0)) }
        )

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: audio)

        // 結果是另一條非同步串流，要和分析同時讀，否則分析會卡住。
        let collector = Task<[TranscriptSegment], Error> {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                guard let segment = Self.makeSegment(from: result) else { continue }
                segments.append(segment)
                onEvent(.segments([segment]))
                if duration > 0 {
                    onEvent(.progress(min(1, segment.end / duration)))
                }
            }
            return segments
        }

        onEvent(.status("轉錄中"))
        do {
            try await withTaskCancellationHandler {
                if let lastSample = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collector.cancel()
            throw error
        }

        let segments = try await collector.value
        try Task.checkCancellation()
        return EngineResult(segments: segments, detectedLanguage: locale.identifier(.bcp47))
    }

    /// 建立辨識器：確認授權、找出系統支援的語言、必要時下載語言包。檔案轉錄與即時字幕共用。
    static func makeTranscriber(
        language: TranscriptionLanguage,
        reportingOptions: Set<SpeechTranscriber.ReportingOption>,
        attributeOptions: Set<SpeechTranscriber.ResultAttributeOption> = [.audioTimeRange],
        onStatus: (String) -> Void
    ) async throws -> (SpeechTranscriber, Locale) {
        guard let identifier = language.appleLocaleIdentifier else { throw AppleSpeechEngineError.languageRequired }
        try await ensureAuthorized()

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw AppleSpeechEngineError.unsupportedLanguage(identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
            attributeOptions: attributeOptions
        )

        onStatus("確認語言模型")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus("下載 Apple 語言模型")
            try await request.downloadAndInstall()
        }
        return (transcriber, locale)
    }

    /// 把一個辨識結果拆成帶時間的片語。AttributedString 的每個 run 帶自己的時間範圍，
    /// 之後分講者時可以在片語邊界切開不同人的話。
    static func makeSegment(from result: SpeechTranscriber.Result) -> TranscriptSegment? {
        let text = result.text
        var words: [TimedWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters)
            guard !piece.isEmpty else { continue }
            words.append(TimedWord(text: piece, start: range.start.seconds, end: range.end.seconds))
        }

        let fullText = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else { return nil }

        let start = result.range.start.seconds
        let end = result.range.end.seconds
        return TranscriptSegment(
            start: start.isFinite ? start : (words.first?.start ?? 0),
            end: end.isFinite ? end : (words.last?.end ?? 0),
            text: fullText,
            words: words
        )
    }

    /// App 第一次用快速模式時跳出系統的語音辨識授權詢問。
    /// 沒有 Info.plist 說明文字的執行檔（例如命令列測試工具）呼叫授權會直接被系統終止，所以先檢查。
    /// 只有使用者明確拒絕時才擋下；其餘情況交給 SpeechAnalyzer 自己回報錯誤。
    private static func ensureAuthorized() async throws {
        let hasUsageDescription = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined where hasUsageDescription:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            if status == .denied { throw AppleSpeechEngineError.notAuthorized }
        case .denied where hasUsageDescription:
            throw AppleSpeechEngineError.notAuthorized
        default:
            return
        }
    }
}
