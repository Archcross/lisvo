import FluidAudio
import Foundation

/// FluidAudio 的 OfflineDiarizerManager 不是 Sendable。它在 prepareModels 之後只讀不寫
///（FluidAudio 原始碼註解也這樣說明），所以包一層手動標記，讓它能從 actor 交給背景工作。
final class DiarizerManagerBox: @unchecked Sendable {
    let manager: OfflineDiarizerManager
    init(manager: OfflineDiarizerManager) { self.manager = manager }
}

/// 分講者：FluidAudio 的離線 VBx 流程（pyannote 分段＋WeSpeaker 聲紋＋VBx 分群），跑在 Neural Engine 上。
/// 這是 FluidAudio 文件裡整段檔案處理品質最好的選項，講者人數沒有上限。
public actor Diarizer {
    public static let shared = Diarizer()

    private var preparedManagers: [Int: DiarizerManagerBox] = [:]

    /// - Parameter speakerCount: 已知人數就填，能明顯減少分錯；nil 代表自動判斷。
    public func diarize(
        audio: URL,
        speakerCount: Int?,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async throws -> [SpeakerTurn] {
        let box = try await manager(for: speakerCount, onEvent: onEvent)
        onEvent(.status("分辨講者"))
        let segments = try await Self.process(box, audio: audio, onEvent: onEvent)
        try Task.checkCancellation()
        return Self.relabel(segments)
    }

    private nonisolated static func process(
        _ box: DiarizerManagerBox,
        audio: URL,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async throws -> [TimedSpeakerSegment] {
        let result = try await box.manager.process(audio) { done, total in
            guard total > 0 else { return }
            onEvent(.progress(Double(done) / Double(total)))
        }
        return result.segments
    }

    private func manager(for speakerCount: Int?, onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> DiarizerManagerBox {
        let key = speakerCount ?? 0
        if let existing = preparedManagers[key] { return existing }

        var config = OfflineDiarizerConfig.default
        if let speakerCount {
            config.clustering.numSpeakers = speakerCount
        }
        // FluidAudio 預設把除錯訊息全部印出來，只留警告以上。
        AppLogger.minimumLevel = .warning
        let box = DiarizerManagerBox(manager: OfflineDiarizerManager(config: config))
        onEvent(.status("準備分講者模型"))
        try await Self.prepare(box)
        preparedManagers[key] = box
        return box
    }

    private nonisolated static func prepare(_ box: DiarizerManagerBox) async throws {
        try await box.manager.prepareModels()
    }

    /// 模型給的講者代號沒有順序意義。改成照第一次開口的順序叫「講者 1、講者 2…」。
    static func relabel(_ segments: [TimedSpeakerSegment]) -> [SpeakerTurn] {
        let sorted = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var names: [String: String] = [:]
        return sorted.map { segment in
            let name: String
            if let existing = names[segment.speakerId] {
                name = existing
            } else {
                name = "講者 \(names.count + 1)"
                names[segment.speakerId] = name
            }
            return SpeakerTurn(
                speaker: name,
                start: Double(segment.startTimeSeconds),
                end: Double(segment.endTimeSeconds)
            )
        }
    }
}
