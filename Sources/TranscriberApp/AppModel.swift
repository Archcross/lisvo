import AppKit
import Foundation
import Observation
import TranscriberCore
import UniformTypeIdentifiers

enum ModeChoice: String, CaseIterable, Identifiable {
    case fast
    case accurate
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: "快速"
        case .accurate: "精準"
        case .both: "比較"
        }
    }

    var engines: [EngineKind] {
        switch self {
        case .fast: [.fast]
        case .accurate: [.accurate]
        case .both: [.fast, .accurate]
        }
    }
}

/// 講者人數選單：0 = 不分講者，-1 = 自動判斷，其餘為指定人數。
enum SpeakerChoice {
    static let off = 0
    static let auto = -1
    static let options: [Int] = [auto, 2, 3, 4, 5, 6, off]

    static func label(_ value: Int) -> String {
        switch value {
        case off: "不分講者"
        case auto: "自動判斷人數"
        default: "\(value) 位講者"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case running
        case finished(URL)
        case failed(String)
        case cancelled
    }

    static let supportedTypes: [UTType] = [.audio, .movie]

    var inputURL: URL?
    var outputDirectory: URL {
        didSet { UserDefaults.standard.set(outputDirectory.path, forKey: Keys.output) }
    }
    var mode: ModeChoice {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            // 快速模式需要指定語言，切過去時把「自動偵測」換成預設語言。
            if mode != .accurate, language == .auto { language = .zhTW }
        }
    }
    var language: TranscriptionLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Keys.language) }
    }
    var speakerChoice: Int {
        didSet { UserDefaults.standard.set(speakerChoice, forKey: Keys.speakers) }
    }
    var polish: Bool {
        didSet { UserDefaults.standard.set(polish, forKey: Keys.polish) }
    }

    private(set) var phase: Phase = .idle
    private(set) var stageText = ""
    private(set) var progress: Double?
    private(set) var sideStageText = ""
    private(set) var notices: [String] = []
    /// 每個模式目前要顯示的句子。轉錄中是即時結果，完成後換成已對好講者的最終結果。
    private(set) var segments: [EngineKind: [TranscriptSegment]] = [:]
    private(set) var finalized: Set<EngineKind> = []
    var visibleEngine: EngineKind = .fast

    private var job: Task<Void, Never>?

    var isRunning: Bool { phase == .running }

    var languageOptions: [TranscriptionLanguage] {
        mode == .accurate ? TranscriptionLanguage.allCases : TranscriptionLanguage.allCases.filter { $0 != .auto }
    }

    var canStart: Bool { inputURL != nil && !isRunning }

    private enum Keys {
        static let output = "outputDirectory"
        static let mode = "mode"
        static let language = "language"
        static let speakers = "speakerChoice"
        static let polish = "polish"
    }

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Keys.output) {
            outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            outputDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("逐字稿", isDirectory: true)
        }
        mode = defaults.string(forKey: Keys.mode).flatMap(ModeChoice.init(rawValue:)) ?? .fast
        language = defaults.string(forKey: Keys.language).flatMap(TranscriptionLanguage.init(rawValue:)) ?? .zhTW
        speakerChoice = defaults.object(forKey: Keys.speakers) as? Int ?? SpeakerChoice.auto
        polish = defaults.bool(forKey: Keys.polish)
        if mode != .accurate, language == .auto { language = .zhTW }
    }

    // MARK: - 選檔

    func setInput(_ url: URL) {
        guard !isRunning else { return }
        inputURL = url
        phase = .idle
        segments = [:]
        finalized = []
        notices = []
        stageText = ""
        sideStageText = ""
        progress = nil
    }

    func chooseInput() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "選擇要轉錄的音檔或影片"
        if panel.runModal() == .OK, let url = panel.url { setInput(url) }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory
        panel.prompt = "選擇"
        panel.message = "逐字稿會存在這個資料夾裡，每次轉錄一個子資料夾"
        if panel.runModal() == .OK, let url = panel.url { outputDirectory = url }
    }

    func revealOutputDirectory() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputDirectory)
    }

    func revealResult() {
        guard case .finished(let folder) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: - 執行

    func start() {
        guard let inputURL, !isRunning else { return }
        let settings = JobSettings(
            engines: mode.engines,
            language: language,
            speakerDetection: speakerChoice != SpeakerChoice.off,
            speakerCount: speakerChoice > 0 ? speakerChoice : nil,
            polish: polish,
            outputDirectory: outputDirectory
        )

        phase = .running
        segments = [:]
        finalized = []
        notices = []
        stageText = "準備中"
        sideStageText = ""
        progress = nil
        visibleEngine = settings.engines[0]

        // 流程在背景跑，事件依序排進這條串流，由主執行緒照順序更新畫面。
        let (events, continuation) = AsyncStream.makeStream(of: PipelineEvent.self, bufferingPolicy: .unbounded)
        let consumer = Task { @MainActor [weak self] in
            for await event in events { self?.handle(event) }
        }

        job = Task { [weak self] in
            let outcome: Phase
            do {
                let result = try await TranscriptionPipeline.run(input: inputURL, settings: settings) { event in
                    continuation.yield(event)
                }
                outcome = .finished(result.outputFolder)
            } catch {
                outcome = (error is CancellationError || Task.isCancelled) ? .cancelled : .failed(error.localizedDescription)
            }
            // 先把已送出的事件處理完，再切換到結束狀態，避免最後的結果被丟掉。
            continuation.finish()
            await consumer.value
            self?.finish(outcome)
        }
    }

    func stop() {
        job?.cancel()
        stageText = "停止中"
    }

    private func finish(_ newPhase: Phase) {
        phase = newPhase
        progress = nil
        sideStageText = ""
        switch newPhase {
        case .finished: stageText = "完成"
        case .cancelled: stageText = "已停止"
        case .failed: stageText = ""
        default: break
        }
        job = nil
    }

    private func handle(_ event: PipelineEvent) {
        guard isRunning else { return }
        switch event {
        case .stage(let engine, let text):
            if let engine {
                stageText = mode == .both ? "\(engine.displayName)：\(text)" : text
                progress = nil
            } else {
                // 分講者和轉錄同時跑，分開顯示，避免兩邊的進度互相覆蓋。
                if segments.isEmpty, finalized.isEmpty { stageText = text } else { sideStageText = text }
            }
        case .progress(let engine, let value):
            if engine != nil { progress = value }
        case .liveSegments(let engine, let newSegments):
            guard !finalized.contains(engine) else { return }
            var current = segments[engine] ?? []
            current.append(contentsOf: newSegments)
            current.sort { $0.start < $1.start }
            segments[engine] = current
            if mode != .both { visibleEngine = engine }
        case .transcriptReady(let engine, let transcript):
            segments[engine] = transcript.segments
            finalized.insert(engine)
        case .notice(let text):
            // 比較模式兩個模式可能各送一次同樣的提示。
            if !notices.contains(text) { notices.append(text) }
        }
    }
}
