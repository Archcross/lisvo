import Foundation
import FoundationModels

public enum PolisherAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
}

/// AI 潤飾：用 Mac 內建的 Foundation Models（Apple Intelligence 的本機模型）修錯字、補標點、刪贅字。
///
/// 這是小模型，一次能讀的文字量有限，所以以「同一位講者連續的一段話」為單位分批送；
/// 太長的段落再按句子切開。每批用新的對話，避免前文累積撐爆上下文。
/// 模型輸出長度差太多時視為改壞了，保留原文。
public enum Polisher {
    /// 每批送進模型的最多字數。上下文要同時容納指示、原文與輸出。
    static let maxCharactersPerChunk = 600
    /// 輸出長度和原文的比例超出這個範圍就不採用。刪贅字會變短，但不該短到一半以下。
    static let acceptableLengthRatio = 0.5...1.3

    public static func availability(for language: TranscriptionLanguage, detectedLanguage: String?) -> PolisherAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Apple Intelligence 沒有開啟。")
        case .unavailable(.deviceNotEligible):
            return .unavailable("這台 Mac 不支援 Apple Intelligence。")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence 模型還在下載。")
        case .unavailable:
            return .unavailable("Apple Intelligence 目前無法使用。")
        }
        if let locale = polishLocale(language: language, detectedLanguage: detectedLanguage),
           !model.supportsLocale(locale) {
            return .unavailable("Mac 內建 AI 不支援這個語言的潤飾。")
        }
        return .available
    }

    static func polishLocale(language: TranscriptionLanguage, detectedLanguage: String?) -> Locale? {
        if language == .zhTW { return Locale(identifier: "zh-Hant-TW") }
        if language == .yue { return Locale(identifier: "zh-Hant-HK") }
        if let id = language.appleLocaleIdentifier { return Locale(identifier: id) }
        if let detectedLanguage { return Locale(identifier: detectedLanguage) }
        return nil
    }

    static func instructions(chinese: Bool) -> String {
        if chinese {
            return """
            你是逐字稿校對員。使用者會給你一段會議或訪談的語音辨識結果。
            請只做以下修正：改正明顯的同音錯字、補上全形標點、刪除「嗯」「呃」「那個」「就是」等無意義的口頭禪與重複字。
            不可改變原意，不可摘要，不可增加原文沒有的內容，不可回答或評論內容。
            一律使用台灣繁體中文。只輸出修正後的文字，不要加任何說明或引號。
            """
        }
        return """
        You proofread speech-recognition transcripts. Fix obvious recognition errors, add punctuation, \
        and remove filler words and stutters. Do not change the meaning, summarize, add content, or reply to the text. \
        Keep the original language. Output only the corrected text, with no notes or quotes.
        """
    }

    struct Chunk {
        var speaker: String?
        var start: Double
        var end: Double
        var text: String
    }

    /// 同一位講者連續的句子合成一批，超過字數上限就在句子邊界切開。
    static func chunks(from segments: [TranscriptSegment], separator: String) -> [Chunk] {
        var result: [Chunk] = []
        for segment in segments {
            if let last = result.indices.last,
               result[last].speaker == segment.speaker,
               result[last].text.count + segment.text.count <= maxCharactersPerChunk {
                result[last].text += separator + segment.text
                result[last].end = segment.end
            } else {
                result.append(Chunk(speaker: segment.speaker, start: segment.start, end: segment.end, text: segment.text))
            }
        }
        return result
    }

    public static func polish(
        _ transcript: Transcript,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async throws -> [PolishedParagraph] {
        let chinese = TextCleanup.isChinese(language: transcript.language, detectedLanguage: transcript.detectedLanguage)
        let separator = Exporter.separator(for: transcript)
        let pieces = chunks(from: transcript.segments, separator: separator)
        let instructionText = instructions(chinese: chinese)

        onEvent(.status("AI 潤飾"))
        var paragraphs: [PolishedParagraph] = []
        for (index, chunk) in pieces.enumerated() {
            try Task.checkCancellation()
            let polishedText = await polishChunk(chunk.text, instructions: instructionText, toTraditional: chinese)
            paragraphs.append(PolishedParagraph(
                start: chunk.start,
                end: chunk.end,
                speaker: chunk.speaker,
                original: chunk.text,
                polished: polishedText ?? chunk.text,
                didPolish: polishedText != nil
            ))
            onEvent(.progress(Double(index + 1) / Double(pieces.count)))
        }
        return paragraphs
    }

    /// 失敗（模型拒絕、超出長度、輸出不合理）時回傳 nil，由呼叫端保留原文。
    static func polishChunk(_ text: String, instructions: String, toTraditional: Bool) async -> String? {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: text,
                options: GenerationOptions(temperature: 0.2)
            )
            var output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            output = output.trimmingCharacters(in: CharacterSet(charactersIn: "「」\"“”"))
            if toTraditional { output = TextCleanup.toTraditional(output) }
            guard !output.isEmpty else { return nil }
            let ratio = Double(output.count) / Double(max(1, text.count))
            guard acceptableLengthRatio.contains(ratio) else { return nil }
            return output
        } catch {
            return nil
        }
    }
}
