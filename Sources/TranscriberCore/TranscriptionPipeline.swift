import Foundation

public struct JobSettings: Sendable {
    /// 一個或兩個模式。兩個時依序執行，各自輸出一組檔案。
    public var engines: [EngineKind]
    public var language: TranscriptionLanguage
    public var speakerDetection: Bool
    /// nil 代表自動判斷人數。
    public var speakerCount: Int?
    public var polish: Bool
    public var outputDirectory: URL

    public init(engines: [EngineKind], language: TranscriptionLanguage, speakerDetection: Bool, speakerCount: Int?, polish: Bool, outputDirectory: URL) {
        self.engines = engines
        self.language = language
        self.speakerDetection = speakerDetection
        self.speakerCount = speakerCount
        self.polish = polish
        self.outputDirectory = outputDirectory
    }
}

public enum PipelineEvent: Sendable {
    /// 目前在做什麼。engine 為 nil 代表和模式無關的步驟（讀取音檔、分講者）。
    case stage(EngineKind?, String)
    case progress(EngineKind?, Double)
    case liveSegments(EngineKind, [TranscriptSegment])
    /// 這個模式的最終結果（已對好講者、已潤飾）。
    case transcriptReady(EngineKind, Transcript)
    /// 某一步失敗但不影響整體，例如 AI 潤飾無法使用。
    case notice(String)
}

public enum PipelineError: LocalizedError {
    case noEngines

    public var errorDescription: String? {
        switch self {
        case .noEngines: "沒有選擇辨識模式。"
        }
    }
}

public struct PipelineResult: Sendable {
    public var outputFolder: URL
    public var files: [URL]
    public var transcripts: [EngineKind: Transcript]
}

/// 一次轉錄的完整流程：讀音檔 → 轉錄（與分講者同時進行）→ 對講者 → 潤飾 → 匯出。
public enum TranscriptionPipeline {
    public static func run(
        input: URL,
        settings: JobSettings,
        onEvent: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws -> PipelineResult {
        guard !settings.engines.isEmpty else { throw PipelineError.noEngines }
        let started = Date()

        // 長錄音可能跑很久，期間不讓 Mac 進入睡眠。
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "轉錄音檔"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcriber-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        onEvent(.stage(nil, "讀取音檔"))
        let audio = try await AudioNormalizer.normalize(input, into: workDirectory)

        // 分講者和轉錄互不依賴，同時開始；兩種模式共用同一份分講者結果。
        let speakerCount = settings.speakerCount
        let diarization: Task<[SpeakerTurn], Error>? = settings.speakerDetection
            ? Task {
                try await Diarizer.shared.diarize(audio: audio.url, speakerCount: speakerCount) { event in
                    switch event {
                    case .status(let text): onEvent(.stage(nil, text))
                    case .progress(let value): onEvent(.progress(nil, value))
                    case .segments: break
                    }
                }
            }
            : nil

        var transcripts: [EngineKind: Transcript] = [:]
        var files: [URL] = []
        let baseName = input.deletingPathExtension().lastPathComponent
        let folder = uniqueFolder(in: settings.outputDirectory, baseName: baseName)

        do {
            for (index, engineKind) in settings.engines.enumerated() {
                // 第一個模式從讀音檔開始算；比較模式的第二個只算它自己的轉錄時間。
                let engineStarted = index == 0 ? started : Date()
                let engine: any SpeechEngine = switch engineKind {
                case .fast: AppleSpeechEngine()
                case .accurate: WhisperEngine()
                }
                // 精準模式要先拿到分講者結果才能開始；快速模式先轉錄，之後再對講者。
                var turnsBeforeTranscription: [SpeakerTurn]?
                if engine.transcribesPerSpeakerTurn, let diarization {
                    onEvent(.stage(engineKind, "等待分辨講者完成"))
                    turnsBeforeTranscription = try await awaitTurns(diarization, onEvent: onEvent)
                }

                let result = try await engine.transcribe(
                    audio: audio.url,
                    duration: audio.duration,
                    language: settings.language,
                    speakerTurns: turnsBeforeTranscription
                ) { event in
                    switch event {
                    case .status(let text): onEvent(.stage(engineKind, text))
                    case .progress(let value): onEvent(.progress(engineKind, value))
                    case .segments(let segments):
                        // 即時顯示也套用中文排版；自動偵測語言時要等結果出來才知道，先不處理。
                        let tidied = segments.map { segment in
                            var copy = segment
                            copy.text = TextCleanup.tidy(segment.text, chinese: settings.language.wantsTraditionalChinese)
                            return copy
                        }
                        onEvent(.liveSegments(engineKind, tidied))
                    }
                }

                var segments = result.segments
                var hasSpeakers = turnsBeforeTranscription != nil
                if !engine.transcribesPerSpeakerTurn, let diarization {
                    onEvent(.stage(engineKind, "等待分辨講者完成"))
                    if let turns = try await awaitTurns(diarization, onEvent: onEvent) {
                        segments = SpeakerAssigner.assign(turns: turns, to: segments)
                        hasSpeakers = true
                    }
                }
                let chinese = TextCleanup.isChinese(language: settings.language, detectedLanguage: result.detectedLanguage)
                segments = segments.compactMap { segment in
                    var copy = segment
                    copy.text = TextCleanup.tidy(segment.text, chinese: chinese)
                    return copy.text.isEmpty ? nil : copy
                }

                var transcript = Transcript(
                    sourceFileName: input.lastPathComponent,
                    engine: engineKind,
                    language: settings.language,
                    detectedLanguage: result.detectedLanguage,
                    audioDuration: audio.duration,
                    processingSeconds: 0,
                    speakerDetection: hasSpeakers,
                    segments: segments
                )

                if settings.polish {
                    switch Polisher.availability(for: settings.language, detectedLanguage: result.detectedLanguage) {
                    case .available:
                        transcript.polished = try await Polisher.polish(transcript) { event in
                            switch event {
                            case .status(let text): onEvent(.stage(engineKind, text))
                            case .progress(let value): onEvent(.progress(engineKind, value))
                            case .segments: break
                            }
                        }
                    case .unavailable(let reason):
                        onEvent(.notice("略過 AI 潤飾：\(reason)"))
                    }
                }

                transcript.processingSeconds = Date().timeIntervalSince(engineStarted)
                let suffix = settings.engines.count > 1 ? "_\(engineKind.displayName)" : ""
                files += try Exporter.write(transcript, baseName: baseName, suffix: suffix, to: folder)
                transcripts[engineKind] = transcript
                onEvent(.transcriptReady(engineKind, transcript))
            }
        } catch {
            diarization?.cancel()
            throw error
        }

        return PipelineResult(outputFolder: folder, files: files, transcripts: transcripts)
    }

    /// 等分講者完成。等待中按下停止時，連分講者一起取消。
    /// 分講者本身失敗（例如模型下載不了）時不讓整個工作失敗：回傳 nil，改成不分講者繼續，並提示使用者。
    private static func awaitTurns(
        _ diarization: Task<[SpeakerTurn], Error>,
        onEvent: @Sendable (PipelineEvent) -> Void
    ) async throws -> [SpeakerTurn]? {
        do {
            return try await withTaskCancellationHandler {
                try await diarization.value
            } onCancel: {
                diarization.cancel()
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            onEvent(.notice("分辨講者失敗，改為不分講者：\(error.localizedDescription)"))
            return nil
        }
    }

    /// 每次轉錄放進自己的資料夾：「檔名 2026-10-28 2130」，同名時加序號。
    static func uniqueFolder(in directory: URL, baseName: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stem = "\(baseName) \(formatter.string(from: Date()))"
        var candidate = directory.appendingPathComponent(stem, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(index))", isDirectory: true)
            index += 1
        }
        return candidate
    }
}
