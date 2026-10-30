import Foundation
import WhisperKit

/// WhisperKit 的物件不是 Sendable。模型只在 WhisperModelStore 裡建立一次，之後只拿來呼叫 transcribe；
/// WhisperKit 自己內部也會對同一個物件平行呼叫 transcribe（VAD 分段時），所以這裡手動標記。
final class WhisperKitBox: @unchecked Sendable {
    let kit: WhisperKit
    init(kit: WhisperKit) { self.kit = kit }
}

/// 管理 Whisper 模型的下載與載入。載入一次約數秒到數分鐘（第一次要讓系統針對 Neural Engine 編譯），
/// 所以整個 App 共用同一份。
public actor WhisperModelStore {
    public static let shared = WhisperModelStore()

    /// large-v3-turbo 的 Core ML 版本（OpenAI 2024-09-30 發布，所以叫 v20240930）。
    public static let modelVariant = "openai_whisper-large-v3-v20240930"

    private var loaded: WhisperKitBox?

    public static var modelsDirectory: URL { ModelLocations.whisper }

    /// 記住模型下載到哪個資料夾，下次直接從本機載入，不必連網確認。
    /// 存的是相對於 modelsDirectory 的路徑，整個資料夾搬家後仍然有效。
    private static var locationMarker: URL {
        modelsDirectory.appendingPathComponent("whisper-model-location.txt")
    }

    public static func isModelDownloaded() -> Bool {
        localModelFolder() != nil
    }

    private static func localModelFolder() -> URL? {
        guard let path = try? String(contentsOf: locationMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else { return nil }
        let folder = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : modelsDirectory.appendingPathComponent(path, isDirectory: true)
        let encoder = folder.appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path) ? folder : nil
    }

    /// 模型在 modelsDirectory 裡時存相對路徑；不在裡面（理論上不會發生）就存完整路徑。
    static func relativePath(of folder: URL) -> String {
        let base = modelsDirectory.standardizedFileURL.path + "/"
        let path = folder.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    func model(onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> WhisperKitBox {
        if let loaded { return loaded }

        let folder: URL
        if let local = Self.localModelFolder() {
            folder = local
        } else {
            onEvent(.status("下載 Whisper 模型（約 1.5 GB，只需一次）"))
            try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
            folder = try await WhisperKit.download(
                variant: Self.modelVariant,
                downloadBase: Self.modelsDirectory,
                progressCallback: { progress in
                    onEvent(.progress(progress.fractionCompleted))
                }
            )
            try Self.relativePath(of: folder).write(to: Self.locationMarker, atomically: true, encoding: .utf8)
        }

        onEvent(.status("載入 Whisper 模型（第一次會比較久）"))
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        let box = WhisperKitBox(kit: try await WhisperKit(config))
        loaded = box
        return box
    }
}

/// 一段要單獨交給 Whisper 的聲音：同一位講者連續說話的範圍。
struct AudioRegion: Equatable, Sendable {
    var start: Double
    var end: Double
    var speaker: String?
    var duration: Double { end - start }
}

/// 精準模式：Whisper large-v3-turbo，用 Core ML 跑在 Apple 晶片的 GPU／Neural Engine 上。
///
/// 有分講者時，先分講者，再把每位講者連續說話的那段聲音分別轉錄。
/// 原因：WhisperKit 對中文給的逐字時間不可靠（實測常有十幾個字擠在同一個時間點），
/// 不能像快速模式那樣先轉整檔再按字詞時間切講者。按講者段落轉錄後，講者一定對，
/// 句子的時間以分講者模型的段落為基準。
public struct WhisperEngine: SpeechEngine {
    /// 選繁體中文時給模型的開頭提示，讓它傾向輸出繁體字與全形標點。
    static let traditionalChinesePrompt = "以下是繁體中文的逐字稿，包含標點符號。"
    /// 同一位講者兩段話間隔不超過這個秒數就併成一段，減少切太碎、也讓模型有前後文。
    static let mergeGap = 1.0
    /// 短於這個秒數的段落（多半是咳嗽、單音節）不送進模型，避免它憑空生出文字。
    static let minimumRegionDuration = 0.3
    /// 每段前後多留一點聲音，避免切掉字頭字尾；只延伸到沒人說話的空檔。
    static let regionPadding = 0.2
    /// 同時轉錄幾段。
    static let maxConcurrentRegions = 4

    public init() {}

    public var transcribesPerSpeakerTurn: Bool { true }

    public func transcribe(
        audio: URL,
        duration: Double,
        language: TranscriptionLanguage,
        speakerTurns: [SpeakerTurn]?,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async throws -> EngineResult {
        let box = try await WhisperModelStore.shared.model(onEvent: onEvent)
        let options = Self.decodingOptions(language: language, kit: box.kit)
        let toTraditional = language.wantsTraditionalChinese

        onEvent(.status("轉錄中"))
        onEvent(.progress(0))
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)

        guard let speakerTurns else {
            return try await transcribeWholeFile(samples, box: box, options: options, duration: duration, toTraditional: toTraditional, onEvent: onEvent)
        }
        let regions = Self.regions(from: speakerTurns, duration: duration)

        var detectedLanguage: String?
        var segments: [TranscriptSegment] = []
        var completedSeconds = 0.0
        let totalSeconds = max(regions.reduce(0) { $0 + $1.duration }, 0.001)

        try await withThrowingTaskGroup(of: (AudioRegion, [TranscriptionResult]).self) { group in
            var pending = regions.makeIterator()

            func addNext() {
                guard let region = pending.next() else { return }
                let slice = Self.slice(samples, region: region)
                group.addTask {
                    let results = try await box.kit.transcribe(
                        audioArray: slice,
                        decodeOptions: options,
                        // 回傳 false 會讓 WhisperKit 停止解碼；按下「停止」時用。
                        callback: { _ in Task.isCancelled ? false : nil }
                    )
                    return (region, results)
                }
            }

            for _ in 0..<Self.maxConcurrentRegions { addNext() }

            while let (region, results) = try await group.next() {
                try Task.checkCancellation()
                detectedLanguage = detectedLanguage ?? results.first?.language
                let converted = results
                    .flatMap(\.segments)
                    .compactMap { Self.convert($0, region: region, toTraditional: toTraditional) }
                segments.append(contentsOf: converted)
                if !converted.isEmpty { onEvent(.segments(converted)) }
                completedSeconds += region.duration
                onEvent(.progress(min(1, completedSeconds / totalSeconds)))
                addNext()
            }
        }

        segments.sort { $0.start < $1.start }
        return EngineResult(segments: segments, detectedLanguage: detectedLanguage)
    }

    /// 不分講者時整個檔案交給 WhisperKit，由它依停頓切段平行處理；每段完成就即時送出。
    private func transcribeWholeFile(
        _ samples: [Float],
        box: WhisperKitBox,
        options: DecodingOptions,
        duration: Double,
        toTraditional: Bool,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async throws -> EngineResult {
        let whole = AudioRegion(start: 0, end: duration, speaker: nil)
        box.kit.segmentDiscoveryCallback = { segments in
            let converted = segments.compactMap { Self.convert($0, region: whole, toTraditional: toTraditional) }
            guard !converted.isEmpty else { return }
            onEvent(.segments(converted))
            if duration > 0, let last = converted.map(\.end).max() {
                onEvent(.progress(min(1, last / duration)))
            }
        }
        defer { box.kit.segmentDiscoveryCallback = nil }

        let results = try await box.kit.transcribe(
            audioArray: samples,
            decodeOptions: options,
            callback: { _ in Task.isCancelled ? false : nil }
        )
        try Task.checkCancellation()
        let segments = results
            .flatMap(\.segments)
            .compactMap { Self.convert($0, region: whole, toTraditional: toTraditional) }
            .sorted { $0.start < $1.start }
        return EngineResult(segments: segments, detectedLanguage: results.first?.language)
    }

    static func decodingOptions(language: TranscriptionLanguage, kit: WhisperKit) -> DecodingOptions {
        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language.whisperCode,
            temperature: 0,
            temperatureFallbackCount: 5,
            usePrefillPrompt: language.whisperCode != nil,
            detectLanguage: language.whisperCode == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            // 逐字時間對中文不可靠，不使用。
            wordTimestamps: false,
            concurrentWorkerCount: 4,
            // 超過 30 秒的段落由 WhisperKit 依停頓再切。
            chunkingStrategy: .vad
        )
        if language.wantsTraditionalChinese, let tokenizer = kit.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + traditionalChinesePrompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        return options
    }

    /// 分講者段落 → 要送進 Whisper 的範圍。
    static func regions(from turns: [SpeakerTurn], duration: Double) -> [AudioRegion] {
        // 1. 同一位講者、間隔很短的段落接起來。
        var merged: [AudioRegion] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            if let last = merged.indices.last,
               merged[last].speaker == turn.speaker,
               turn.start - merged[last].end <= mergeGap {
                merged[last].end = max(merged[last].end, turn.end)
            } else {
                merged.append(AudioRegion(start: turn.start, end: turn.end, speaker: turn.speaker))
            }
        }
        merged.removeAll { $0.duration < minimumRegionDuration }

        // 2. 前後補一點聲音，但不跨進別人說話的範圍，也不超出檔案。
        var padded = merged
        for index in padded.indices {
            let previousEnd = index > 0 ? merged[index - 1].end : 0
            let nextStart = index + 1 < merged.count ? merged[index + 1].start : duration
            let region = merged[index]
            padded[index].start = max(0, min(region.start, max(previousEnd, region.start - regionPadding)))
            padded[index].end = min(duration, max(region.end, min(nextStart, region.end + regionPadding)))
        }
        return padded
    }

    static func slice(_ samples: [Float], region: AudioRegion) -> [Float] {
        let rate = AudioNormalizer.sampleRate
        let lower = max(0, min(samples.count, Int((region.start * rate).rounded(.down))))
        let upper = max(lower, min(samples.count, Int((region.end * rate).rounded(.up))))
        return Array(samples[lower..<upper])
    }

    /// Whisper 給的時間是相對於這段聲音的開頭，加回段落起點，並限制在段落範圍內。
    static func convert(_ segment: TranscriptionSegment, region: AudioRegion, toTraditional: Bool) -> TranscriptSegment? {
        // 模型自己判斷「這裡沒人說話」且信心很低時，多半是憑空生成的句子，丟掉。
        if segment.noSpeechProb > 0.6, segment.avgLogprob < -1.0 { return nil }

        var text = TextCleanup.removingUndecodableBytes(segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if toTraditional { text = TextCleanup.toTraditional(text) }
        guard !text.isEmpty else { return nil }

        let start = min(region.end, region.start + Double(max(0, segment.start)))
        let end = min(region.end, max(start, region.start + Double(segment.end)))
        return TranscriptSegment(start: start, end: end, text: text, speaker: region.speaker)
    }
}
