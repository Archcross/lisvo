import AVFoundation
import Foundation
import Speech

/// 即時字幕送出的事件。
public enum LiveEvent: Sendable {
    /// 正在說、還會被修正的文字。新的會整段取代舊的；空字串代表目前沒有暫定文字。
    case volatile(String)
    /// 已經定案的一句，不會再變。
    case finalized(TranscriptSegment)
}

public enum LiveTranscriberError: LocalizedError {
    case noAudioFormat

    public var errorDescription: String? {
        switch self {
        case .noAudioFormat: "這台 Mac 的內建語音辨識沒有可用的音訊格式。"
        }
    }
}

/// 即時字幕：聲音一邊送進來，一邊出字。用 Mac 內建的 SpeechTranscriber（快速模式同一套），
/// 暫定文字（volatile）先顯示，講完一句再換成定案文字。Whisper 要一段一段處理，延遲太長，不用在這裡。
///
/// 執行緒：`append` 由擷取聲音的那條佇列依序呼叫（同一時間只有一個呼叫），
/// 轉檔器只在 `append` 裡使用；送進辨識器的串流本身可以跨執行緒使用。所以標成 @unchecked Sendable。
public final class LiveTranscriber: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let collector: Task<[TranscriptSegment], Never>
    private var converter: AVAudioConverter?

    private init(
        analyzer: SpeechAnalyzer,
        analyzerFormat: AVAudioFormat,
        input: AsyncStream<AnalyzerInput>.Continuation,
        collector: Task<[TranscriptSegment], Never>
    ) {
        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat
        self.input = input
        self.collector = collector
    }

    /// 準備好辨識器並開始接收聲音。語言包沒裝時會先下載。
    /// - Parameter withEnglish: 同時跑英文辨識器（中英夾雜）。以 `language` 的結果為主，
    ///   裡面聽成亂碼的整句英文換成英文辨識器的結果，合併方式見 BilingualMerge。
    public static func start(
        language: TranscriptionLanguage,
        withEnglish: Bool = false,
        onStatus: @escaping @Sendable (String) -> Void,
        onEvent: @escaping @Sendable (LiveEvent) -> Void
    ) async throws -> LiveTranscriber {
        // 與 Apple 的 timeIndexedProgressiveTranscription 預設相同：暫定文字＋快速出字。
        // 沒有 fastResults 時實測要累積約 12 秒才出第一個字，不能當字幕用。
        let reportingOptions: Set<SpeechTranscriber.ReportingOption> = [.volatileResults, .fastResults]
        let (transcriber, _) = try await AppleSpeechEngine.makeTranscriber(
            language: language,
            reportingOptions: reportingOptions,
            onStatus: onStatus
        )
        var english: SpeechTranscriber?
        if withEnglish {
            // 合併時要用每個字的信心分數判斷英文辨識器是不是把中文硬聽成英文。
            (english, _) = try await AppleSpeechEngine.makeTranscriber(
                language: .en,
                reportingOptions: reportingOptions,
                attributeOptions: [.audioTimeRange, .transcriptionConfidence],
                onStatus: onStatus
            )
        }
        // 兩個辨識器放在同一個分析器裡，吃同一份聲音。
        let modules: [any SpeechModule] = [transcriber] + (english.map { [$0] } ?? [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw LiveTranscriberError.noAudioFormat
        }

        let chinese = language.wantsTraditionalChinese
        // 結果要和分析同時讀，否則辨識會卡住。
        let collector: Task<[TranscriptSegment], Never>
        if let english {
            collector = collectBilingual(primary: transcriber, english: english, chinese: chinese, onEvent: onEvent)
        } else {
            collector = collect(transcriber, chinese: chinese, onEvent: onEvent)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        onStatus("即時字幕中")
        return LiveTranscriber(analyzer: analyzer, analyzerFormat: format, input: continuation, collector: collector)
    }

    private static func collect(
        _ transcriber: SpeechTranscriber,
        chinese: Bool,
        onEvent: @escaping @Sendable (LiveEvent) -> Void
    ) -> Task<[TranscriptSegment], Never> {
        Task {
            var segments: [TranscriptSegment] = []
            do {
                for try await result in transcriber.results {
                    if result.isFinal {
                        guard var segment = AppleSpeechEngine.makeSegment(from: result) else { continue }
                        segment.text = Self.dropLeadingPunctuation(TextCleanup.tidy(segment.text, chinese: chinese))
                        guard !segment.text.isEmpty else { continue }
                        segments.append(segment)
                        onEvent(.finalized(segment))
                        onEvent(.volatile(""))
                    } else {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        onEvent(.volatile(Self.dropLeadingPunctuation(TextCleanup.tidy(text, chinese: chinese))))
                    }
                }
            } catch {
                // 停止或取消時串流會結束或丟錯；已定案的句子照樣回傳。
            }
            return segments
        }
    }

    /// 中英同時辨識：兩個辨識器的結果都交給 BilingualLiveMerger，由它依序送出合併後的事件。
    /// 英文辨識器只用定案結果：暫定結果沒有逐字時間和信心分數（實測），無法判斷哪些字可信。
    private static func collectBilingual(
        primary: SpeechTranscriber,
        english: SpeechTranscriber,
        chinese: Bool,
        onEvent: @escaping @Sendable (LiveEvent) -> Void
    ) -> Task<[TranscriptSegment], Never> {
        let merger = BilingualLiveMerger(
            onEvent: onEvent,
            tidy: { Self.dropLeadingPunctuation(TextCleanup.tidy($0, chinese: chinese)) }
        )
        return Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await result in primary.results {
                            if result.isFinal {
                                guard let segment = AppleSpeechEngine.makeSegment(from: result) else { continue }
                                await merger.chineseFinal(segment)
                            } else {
                                let start = result.range.start.seconds
                                await merger.chineseVolatile(String(result.text.characters), start: start.isFinite ? start : 0)
                            }
                        }
                    } catch {
                        // 停止或取消時串流會結束或丟錯；已定案的句子由 merger 照樣回傳。
                    }
                }
                group.addTask {
                    do {
                        for try await result in english.results where result.isFinal {
                            let end = result.range.end.seconds
                            await merger.englishFinal(Self.englishSentence(from: result), end: end.isFinite ? end : nil)
                        }
                    } catch {
                        // 同上。
                    }
                }
            }
            return await merger.finish()
        }
    }

    /// 英文辨識器定案的一句，連同每個字的時間和信心分數。
    private static func englishSentence(from result: SpeechTranscriber.Result) -> EnglishSentence? {
        let text = result.text
        var scored: [(word: TimedWord, confidence: Double)] = []
        for run in text.runs {
            guard let range = run.audioTimeRange, let confidence = run.transcriptionConfidence else { continue }
            let piece = String(text[run.range].characters)
            guard !piece.isEmpty else { continue }
            scored.append((TimedWord(text: piece, start: range.start.seconds, end: range.end.seconds), confidence))
        }
        return EnglishSentence(words: scored)
    }

    /// 送進一段聲音。任何格式都可以，這裡會轉成辨識器要的格式。
    /// 時間軸假設聲音連續不中斷（電腦聲音和麥克風擷取沒聲音時也會送靜音）。
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let converted = convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// 停止接收聲音，等最後一句定案，回傳這次所有定案的句子。
    public func finish() async -> [TranscriptSegment] {
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        return await collector.value
    }

    /// 即時模式下，上一句的句號常常被歸到下一段開頭（實測「。嗯，那你覺得…」），去掉開頭的標點。
    static func dropLeadingPunctuation(_ text: String) -> String {
        String(text.drop { $0.isPunctuation || $0.isWhitespace })
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sourceFormat = buffer.format
        if sourceFormat == analyzerFormat { return buffer }
        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
        }
        guard let converter else { return nil }

        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }

        // 每次只交出這一段；之後回「暫時沒資料」，轉檔器會保留內部狀態等下一段，重新取樣才不會在段落交界出現雜音。
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
