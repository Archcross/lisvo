import AppKit
import Foundation
import Observation
import TranscriberCore
import Translation
import UniformTypeIdentifiers

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


    var inputURL: URL?
    var outputDirectory: URL {
        didSet { UserDefaults.standard.set(outputDirectory.path, forKey: Keys.output) }
    }
    var mode: EngineKind {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            // 快速模式需要指定語言，切過去時把「自動偵測」換成預設語言。
            if mode == .fast, language == .auto { language = .zhTW }
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
    /// 即時字幕要聽的語言（影片或會議裡說的話）。和檔案轉錄的語言分開記：
    /// Apple 即時辨識不能自動偵測語言，共用同一個選單時，看英文影片很容易忘了切換，結果用中文模型聽英文。
    var liveSource: TranscriptionLanguage {
        didSet {
            UserDefaults.standard.set(liveSource.rawValue, forKey: Keys.liveSource)
            // 換了要聽的語言後，原本的翻譯目標可能變成同一種語言，那就改回不翻譯。
            if liveSource.isSameLanguage(as: liveTranslation) { liveTranslation = .off }
        }
    }
    /// 即時字幕要聽電腦正在播放的聲音，還是麥克風。
    var liveAudio: LiveAudioSource {
        didSet { UserDefaults.standard.set(liveAudio.rawValue, forKey: Keys.liveAudio) }
    }
    /// 即時字幕要翻成哪種語言。
    var liveTranslation: TranslationTarget {
        didSet { UserDefaults.standard.set(liveTranslation.rawValue, forKey: Keys.liveTranslation) }
    }

    /// 即時字幕可以聽的語言：Apple 即時辨識一定要指定，所以沒有「自動偵測」。
    static let liveSourceOptions = TranscriptionLanguage.allCases.filter { $0 != .auto }
    /// 翻譯選單不列出和「聽」同一種的語言，避免中文翻中文。
    var liveTranslationOptions: [TranslationTarget] {
        TranslationTarget.allCases.filter { !liveSource.isSameLanguage(as: $0) }
    }

    private(set) var phase: Phase = .idle
    private(set) var stageText = ""
    private(set) var progress: Double?
    private(set) var sideStageText = ""
    private(set) var notices: [String] = []
    /// 目前要顯示的句子。轉錄中是即時結果，完成後換成已對好講者的最終結果。
    private(set) var segments: [TranscriptSegment] = []
    private(set) var isFinalized = false
    /// 原始音檔的播放器。點逐字稿的某句就只播那一句。
    let playback = AudioPlayback()
    /// 最後點的那一句，用來標亮。
    private var playingSegmentID: UUID?

    private var job: Task<Void, Never>?

    /// iPhone 分享過來的音檔所在的 iCloud 資料夾；沒開 iCloud 雲碟時是 nil，這個功能整個不啟用。
    let inbox: InboxFolders?
    private var inboxScanner = InboxScanner()
    /// 已經同步完整、排隊等著轉的手機音檔。
    private(set) var inboxQueue: [URL] = []
    /// 正在轉的手機音檔。
    private(set) var currentInboxFile: URL?
    /// 目前顯示的音檔是不是從手機來的；是的話逐字稿存到 iCloud，輸出列也顯示 iCloud 的位置。
    private(set) var inputFromInbox = false
    /// 這次開著 App 期間轉失敗或被停止的手機音檔。留在收件資料夾，下次開 App 再試，這次不自動重試，避免一直失敗一直重來。
    private var skippedInboxFiles: Set<URL> = []
    private var inboxTask: Task<Void, Never>?

    /// 即時字幕進行中（從按下開始到最後一句定案、存檔完成）。
    private(set) var isLive = false
    /// 正在準備（確認語言包、取得錄音權限），這段時間按鈕不能再按。
    private(set) var isStartingLive = false
    /// 正在說、還會被修正的文字。
    private(set) var liveVolatile = ""
    private var liveTranscriber: LiveTranscriber?
    private var liveCapture: (any LiveAudioCapture)?
    /// 這次字幕實際用的聲音來源；存檔時寫進逐字稿。
    private(set) var liveAudioInUse: LiveAudioSource = .system
    private var liveEvents: AsyncStream<LiveEvent>.Continuation?
    private var liveConsumer: Task<Void, Never>?
    private var liveStartedAt: Date?
    private var liveLanguage: TranscriptionLanguage = .zhTW
    private let subtitleWindow = SubtitleWindowController()

    /// 這次字幕有沒有開翻譯；決定字幕視窗要不要顯示譯文那一行。
    private(set) var isTranslatingLive = false
    /// 字幕視窗的譯文：目前這段裡最後兩句已翻好的句子。
    private(set) var liveTranslationLine = ""
    /// 要下載的翻譯語言包。設定後主視窗會跳出系統的下載提示，下載完呼叫 translationDownloadFinished。
    private(set) var translationDownloadRequest: TranslationSession.Configuration?
    private var liveTranslationTarget: TranslationTarget = .off
    /// 原句 → 譯文。同一句（暫定時看過、定案後又出現）只翻一次。
    private var translationCache: [String: String] = [:]
    private var translationRequested: Set<String> = []
    private var translationQueue: AsyncStream<String>.Continuation?
    private var translationWorker: Task<Void, Never>?

    var isRunning: Bool { phase == .running }

    var languageOptions: [TranscriptionLanguage] {
        mode == .accurate ? TranscriptionLanguage.allCases : TranscriptionLanguage.allCases.filter { $0 != .auto }
    }

    var canStart: Bool { inputURL != nil && !isRunning && !isLive }

    private enum Keys {
        static let output = "outputDirectory"
        static let mode = "mode"
        static let language = "language"
        static let speakers = "speakerChoice"
        static let polish = "polish"
        static let liveTranslation = "liveTranslation"
        static let liveSource = "liveSource"
        static let liveAudio = "liveAudio"
    }

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Keys.output) {
            outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            outputDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("逐字稿", isDirectory: true)
        }
        // 舊版存過「比較」（both），讀不到對應的模式時退回快速。
        mode = defaults.string(forKey: Keys.mode).flatMap(EngineKind.init(rawValue:)) ?? .fast
        language = defaults.string(forKey: Keys.language).flatMap(TranscriptionLanguage.init(rawValue:)) ?? .zhTW
        speakerChoice = defaults.object(forKey: Keys.speakers) as? Int ?? SpeakerChoice.auto
        polish = defaults.bool(forKey: Keys.polish)
        var source = defaults.string(forKey: Keys.liveSource).flatMap(TranscriptionLanguage.init(rawValue:)) ?? .zhTW
        if source == .auto { source = .zhTW }
        let savedTranslation = defaults.string(forKey: Keys.liveTranslation).flatMap(TranslationTarget.init(rawValue:)) ?? .off
        liveSource = source
        liveAudio = defaults.string(forKey: Keys.liveAudio).flatMap(LiveAudioSource.init(rawValue:)) ?? .system
        liveTranslation = source.isSameLanguage(as: savedTranslation) ? .off : savedTranslation
        inbox = Self.prepareInbox()
        if mode == .fast, language == .auto { language = .zhTW }
        startWatchingInbox()
    }

    // MARK: - 選檔

    func setInput(_ url: URL) {
        setInput(url, fromInbox: false)
    }

    private func setInput(_ url: URL, fromInbox: Bool) {
        guard !isRunning, !isLive else { return }
        inputURL = url
        inputFromInbox = fromInbox
        playback.load(url)
        playingSegmentID = nil
        phase = .idle
        segments = []
        isFinalized = false
        notices = []
        stageText = ""
        sideStageText = ""
        progress = nil
    }

    func chooseInput() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SupportedMedia.types
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

    /// 這次轉錄的逐字稿會存到哪裡：手機來的放 iCloud，其他照使用者設定。
    var activeOutputDirectory: URL {
        if inputFromInbox, let inbox { return inbox.transcripts }
        return outputDirectory
    }

    /// 輸出列顯示用的路徑。iCloud 的實際路徑很長，改成 Finder 裡看到的名稱。
    var activeOutputDisplayPath: String {
        if inputFromInbox, inbox != nil { return "iCloud 雲碟/Lisvo/逐字稿" }
        return (outputDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    func revealOutputDirectory() {
        if inputFromInbox, let inbox {
            NSWorkspace.shared.open(inbox.transcripts)
            return
        }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputDirectory)
    }

    func revealResult() {
        guard case .finished(let folder) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: - 播放

    /// 只播這一句：從句首播到句尾就停。
    func play(_ segment: TranscriptSegment) {
        playingSegmentID = segment.id
        playback.playClip(from: segment.start, to: segment.end)
    }

    /// 要標亮的那一句。
    /// - 點過某句：標那一句。不用播放時間反推，因為句尾的時間常常等於下一句的開頭，播完會誤標到下一句。
    /// - 沒點過、直接按空白鍵一路播：標開始時間不晚於目前播放位置的最後一句。
    ///   句子之間的空檔仍標著上一句，畫面才不會一閃一閃。
    var activeSegmentID: UUID? {
        guard playback.hasStarted, !segments.isEmpty else { return nil }
        // 轉錄完成時句子會整批換成最終結果，舊的 id 找不到，就改用播放時間推算。
        if playback.clip != nil, let id = playingSegmentID, segments.contains(where: { $0.id == id }) {
            return id
        }
        let time = playback.currentTime
        var low = 0
        var high = segments.count - 1
        var found: Int?
        // segments 已依開始時間排序，用二分搜尋。
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found.map { segments[$0].id }
    }

    // MARK: - 執行

    func start() {
        guard let inputURL, !isRunning else { return }
        let settings = JobSettings(
            engine: mode,
            language: language,
            speakerDetection: speakerChoice != SpeakerChoice.off,
            speakerCount: speakerChoice > 0 ? speakerChoice : nil,
            polish: polish,
            outputDirectory: activeOutputDirectory
        )

        phase = .running
        segments = []
        isFinalized = false
        playingSegmentID = nil
        notices = []
        stageText = "準備中"
        sideStageText = ""
        progress = nil

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
        finishInboxFile(newPhase)
    }

    // MARK: - 即時字幕

    /// 浮動字幕的兩行：有暫定文字時顯示「上一句定案＋正在說的」，沒有時顯示最後兩句定案。
    var subtitleLines: (previous: String, current: String) {
        if !liveVolatile.isEmpty { return (segments.last?.text ?? "", liveVolatile) }
        if segments.count >= 2 { return (segments[segments.count - 2].text, segments[segments.count - 1].text) }
        return ("", segments.last?.text ?? "")
    }

    func toggleLive() {
        Task {
            if isLive { await stopLive() } else { await startLive() }
        }
    }

    /// 擷取電腦聲音或麥克風、即時辨識，字幕顯示在浮動視窗，定案的句子同時列在主視窗。
    /// 只用 Mac 內建辨識（Whisper 要一段一段處理，延遲太長），不分講者、不潤飾；語言用「聽」選的那一種。
    private func startLive() async {
        guard !isLive, !isStartingLive, !isRunning else { return }
        isStartingLive = true
        isLive = true
        defer { isStartingLive = false }

        playback.unload()
        inputURL = nil
        inputFromInbox = false
        playingSegmentID = nil
        phase = .idle
        segments = []
        isFinalized = false
        notices = []
        liveVolatile = ""
        sideStageText = ""
        progress = nil
        stageText = "準備即時字幕"
        liveLanguage = liveSource
        liveAudioInUse = liveAudio

        // 辨識結果依序排進串流，由主執行緒照順序更新畫面，避免先後顛倒。
        let (events, continuation) = AsyncStream.makeStream(of: LiveEvent.self, bufferingPolicy: .unbounded)
        liveEvents = continuation
        liveConsumer = Task { @MainActor [weak self] in
            for await event in events { self?.handleLive(event) }
        }

        do {
            let transcriber = try await LiveTranscriber.start(
                language: liveLanguage,
                onStatus: { [weak self] text in Task { @MainActor in self?.stageText = text } },
                onEvent: { continuation.yield($0) }
            )
            let capture = liveAudioInUse.makeCapture(
                onBuffer: { transcriber.append($0) },
                onStop: { [weak self] error in Task { @MainActor in self?.liveStoppedBySystem(error) } }
            )
            do {
                try await capture.start()
            } catch {
                _ = await transcriber.finish()
                throw error
            }
            liveTranscriber = transcriber
            liveCapture = capture
            liveStartedAt = Date()
            stageText = "即時字幕中"
            await prepareLiveTranslation()
            subtitleWindow.show(model: self, translating: isTranslatingLive)
        } catch {
            continuation.finish()
            await liveConsumer?.value
            liveEvents = nil
            liveConsumer = nil
            resetLiveTranslation()
            isLive = false
            stageText = ""
            phase = .failed(error.localizedDescription)
        }
    }

    /// 停止擷取，等最後一句定案，存成和檔案轉錄相同格式的逐字稿（存到本機的輸出資料夾）。
    private func stopLive() async {
        guard isLive, !isStartingLive, let transcriber = liveTranscriber else { return }
        stageText = "結束即時字幕"
        let capture = liveCapture
        liveCapture = nil
        liveTranscriber = nil
        await capture?.stop()
        let finalSegments = await transcriber.finish()
        liveEvents?.finish()
        await liveConsumer?.value
        liveEvents = nil
        liveConsumer = nil
        // 最後幾句還在排隊翻譯，等它們翻完再存檔。
        translationQueue?.finish()
        await translationWorker?.value
        let translated = translationWorker != nil ? translationCache : nil
        let translationTarget = liveTranslationTarget
        resetLiveTranslation()
        subtitleWindow.hide()
        liveVolatile = ""
        segments = finalSegments
        isFinalized = true
        isLive = false

        guard !finalSegments.isEmpty else {
            stageText = "已停止（沒有辨識到文字）"
            return
        }
        let duration = Date().timeIntervalSince(liveStartedAt ?? Date())
        let transcript = Transcript(
            sourceFileName: liveAudioInUse.label,
            engine: .fast,
            language: liveLanguage,
            detectedLanguage: nil,
            audioDuration: duration,
            processingSeconds: duration,
            speakerDetection: false,
            segments: finalSegments
        )
        let folder = TranscriptionPipeline.uniqueFolder(in: outputDirectory, baseName: "即時字幕")
        do {
            _ = try Exporter.write(transcript, baseName: "即時字幕", to: folder)
            if let translated {
                let text = LiveTranslationExport.text(segments: finalSegments, cache: translated, target: translationTarget)
                try text.write(to: folder.appendingPathComponent("即時字幕_翻譯.txt"), atomically: true, encoding: .utf8)
            }
            phase = .finished(folder)
            stageText = "已存檔"
        } catch {
            phase = .failed("即時字幕存檔失敗：\(error.localizedDescription)")
        }
    }

    private func handleLive(_ event: LiveEvent) {
        guard isLive else { return }
        switch event {
        case .volatile(let text):
            liveVolatile = text
            // 暫定文字裡已經講完的句子就先翻，不等定案（定案約 15 秒一次，等它譯文會落後太多）。
            requestTranslation(of: SentenceSplitter.split(text).complete)
        case .finalized(let segment):
            segments.append(segment)
            requestTranslation(of: SentenceSplitter.allSentences(segment.text))
        }
        refreshTranslationLine()
    }

    // MARK: - 即時翻譯

    /// 決定這次字幕要不要翻譯：語言包已安裝就開始；還沒下載就請主視窗跳出下載提示，字幕先不翻。
    private func prepareLiveTranslation() async {
        resetLiveTranslation()
        liveTranslationTarget = liveTranslation
        guard liveTranslation != .off,
              let source = liveLanguage.translationSource,
              let target = liveTranslation.language
        else { return }
        if liveLanguage.isSameLanguage(as: liveTranslation) {
            notices.append(LiveTranslatorError.sameLanguage.localizedDescription)
            return
        }
        isTranslatingLive = true
        switch await LiveTranslator.status(from: source, to: target) {
        case .installed:
            startTranslationWorker(source: source, target: target)
        case .supported:
            liveTranslationLine = "下載翻譯語言包中…"
            translationDownloadRequest = TranslationSession.Configuration(source: source, target: target)
        case .unsupported:
            isTranslatingLive = false
            notices.append(LiveTranslatorError.unsupported.localizedDescription)
        @unknown default:
            isTranslatingLive = false
        }
    }

    /// 主視窗的下載提示結束後呼叫（下載完成或使用者取消都會呼叫）。
    func translationDownloadFinished() async {
        guard let request = translationDownloadRequest else { return }
        translationDownloadRequest = nil
        guard isLive, isTranslatingLive, let source = request.source, let target = request.target else { return }
        if await LiveTranslator.status(from: source, to: target) == .installed {
            liveTranslationLine = ""
            startTranslationWorker(source: source, target: target)
            // 下載期間已經定案的句子補翻，存檔時譯文才完整。
            for segment in segments {
                requestTranslation(of: SentenceSplitter.allSentences(segment.text))
            }
        } else {
            isTranslatingLive = false
            liveTranslationLine = ""
            notices.append("沒有下載翻譯語言包，這次字幕不翻譯。")
        }
    }

    /// 一條工作依序翻譯排進來的句子，翻好就更新字幕的譯文行。
    private func startTranslationWorker(source: Locale.Language, target: Locale.Language) {
        let translator = LiveTranslator(source: source, target: target)
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        translationQueue = continuation
        translationWorker = Task { @MainActor [weak self] in
            for await sentence in stream {
                // 翻譯失敗的句子記成空字串，不重試，避免卡住後面的句子。
                let translated = (try? await translator.translate(sentence)) ?? ""
                guard let self else { return }
                self.translationCache[sentence] = translated
                self.refreshTranslationLine()
            }
        }
    }

    private func requestTranslation(of sentences: [String]) {
        guard let translationQueue else { return }
        for sentence in sentences where !translationRequested.contains(sentence) {
            translationRequested.insert(sentence)
            translationQueue.yield(sentence)
        }
    }

    /// 譯文行顯示目前這段文字裡最後兩句已翻好的句子；這段還沒有翻好的句子時，保留上一行，畫面不會閃空。
    private func refreshTranslationLine() {
        guard translationQueue != nil else { return }
        let sentences = liveVolatile.isEmpty
            ? SentenceSplitter.allSentences(segments.last?.text ?? "")
            : SentenceSplitter.split(liveVolatile).complete
        let translated = sentences.compactMap { translationCache[$0] }.filter { !$0.isEmpty }
        guard !translated.isEmpty else { return }
        liveTranslationLine = translated.suffix(2).joined(separator: liveTranslationTarget.sentenceJoiner)
    }

    private func resetLiveTranslation() {
        translationQueue?.finish()
        translationWorker?.cancel()
        translationQueue = nil
        translationWorker = nil
        translationCache = [:]
        translationRequested = []
        translationDownloadRequest = nil
        liveTranslationLine = ""
        isTranslatingLive = false
    }

    /// 中途停止擷取（例如從選單列的錄製圖示關掉、換了麥克風後接不回去）：照常結束並存檔。
    private func liveStoppedBySystem(_ error: Error) {
        guard isLive, liveCapture != nil else { return }
        notices.append("聲音擷取中斷：\(error.localizedDescription)")
        Task { await stopLive() }
    }

    // MARK: - iPhone 收件（iCloud）

    func revealInbox() {
        guard let inbox else { return }
        NSWorkspace.shared.open(inbox.root)
    }

    private static func prepareInbox() -> InboxFolders? {
        guard let folders = InboxFolders.iCloud else { return nil }
        do {
            try folders.createIfNeeded()
            return folders
        } catch {
            return nil
        }
    }

    /// 每 3 秒看一次收件資料夾。檔案要連續兩次大小一樣才算同步完，所以新檔案大約 3 到 6 秒後開始轉。
    private func startWatchingInbox() {
        guard inbox != nil else { return }
        inboxTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollInbox()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func pollInbox() {
        guard let inbox else { return }
        let ready = inboxScanner.readyFiles(in: inbox.inbox)
        inboxQueue = ready.filter { !skippedInboxFiles.contains($0) && $0 != currentInboxFile }
        startNextInboxFileIfIdle()
    }

    /// 手機來的音檔收到就自動轉，用目前的模式、語言、講者與潤飾設定。
    /// 正在轉錄或正在聽某一句時不打斷，等下一輪再看。
    private func startNextInboxFileIfIdle() {
        guard !isRunning, !isLive, !playback.isPlaying, let next = inboxQueue.first else { return }
        inboxQueue.removeFirst()
        setInput(next, fromInbox: true)
        currentInboxFile = next
        start()
    }

    private func finishInboxFile(_ outcome: Phase) {
        guard let file = currentInboxFile else { return }
        currentInboxFile = nil
        guard case .finished = outcome, let inbox else {
            skippedInboxFiles.insert(file)
            return
        }
        do {
            let moved = try inbox.markProcessed(file)
            // 音檔搬走了，播放器改指到新位置，點句播放才能繼續用。
            inputURL = moved
            playback.load(moved)
        } catch {
            skippedInboxFiles.insert(file)
            notices.append("逐字稿已存好，但音檔無法移到「已處理」：\(error.localizedDescription)")
        }
    }

    private func handle(_ event: PipelineEvent) {
        guard isRunning else { return }
        switch event {
        case .stage(let track, let text):
            switch track {
            case .transcription:
                stageText = text
                progress = nil
            case .speakers:
                // 分講者和轉錄同時跑，分開顯示，避免兩邊的進度互相覆蓋。
                if segments.isEmpty, !isFinalized { stageText = text } else { sideStageText = text }
            }
        case .progress(let track, let value):
            if track == .transcription { progress = value }
        case .liveSegments(let newSegments):
            guard !isFinalized else { return }
            segments.append(contentsOf: newSegments)
            segments.sort { $0.start < $1.start }
        case .transcriptReady(let transcript):
            segments = transcript.segments
            isFinalized = true
        case .notice(let text):
            // 保險起見，同樣的提示只顯示一次。
            if !notices.contains(text) { notices.append(text) }
        }
    }
}
