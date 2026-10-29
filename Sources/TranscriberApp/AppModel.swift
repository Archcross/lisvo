import AppKit
import Foundation
import Observation
import TranscriberCore
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
        // 舊版存過「比較」（both），讀不到對應的模式時退回快速。
        mode = defaults.string(forKey: Keys.mode).flatMap(EngineKind.init(rawValue:)) ?? .fast
        language = defaults.string(forKey: Keys.language).flatMap(TranscriptionLanguage.init(rawValue:)) ?? .zhTW
        speakerChoice = defaults.object(forKey: Keys.speakers) as? Int ?? SpeakerChoice.auto
        polish = defaults.bool(forKey: Keys.polish)
        inbox = Self.prepareInbox()
        if mode == .fast, language == .auto { language = .zhTW }
        startWatchingInbox()
    }

    // MARK: - 選檔

    func setInput(_ url: URL) {
        setInput(url, fromInbox: false)
    }

    private func setInput(_ url: URL, fromInbox: Bool) {
        guard !isRunning else { return }
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
        guard !isRunning, !playback.isPlaying, let next = inboxQueue.first else { return }
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
