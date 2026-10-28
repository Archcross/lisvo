import AVFoundation
import Foundation
import Observation

/// 播放原始音檔（或影片的聲音）。點逐字稿的某句時只播那一句，播到句尾自動停。
@MainActor
@Observable
final class AudioPlayback {
    /// 一句話的播放範圍。
    struct Clip: Equatable {
        var start: Double
        var end: Double
    }

    private(set) var isPlaying = false
    /// 目前播到第幾秒。
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// 載入後還沒播過時為 false，這時不標亮任何一句。
    private(set) var hasStarted = false
    /// 正在播（或剛播完）的那一句；nil 代表沒有限定範圍，一路播到檔案結尾。
    private(set) var clip: Clip?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var clipEndObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var loadedURL: URL?
    /// 檔案還沒準備好就被要求播放時，先記下起點，等準備好再跳轉。
    private var pendingStart: Double?
    /// 每次跳轉加一。連點兩句時，前一次跳轉完成的回呼要作廢，不然會先播到上一句。
    private var seekGeneration = 0
    /// 這一句已經播到句尾。再按播放就重播這一句。
    private var clipFinished = false

    var isLoaded: Bool { player != nil }

    func load(_ url: URL) {
        guard url != loadedURL else { return }
        unload()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        loadedURL = url

        // 每 0.1 秒更新一次播放位置，用來標亮正在播的那句。
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.isPlaying = self.player?.timeControlStatus != .paused
                // 句尾的邊界通知是主要的停止機制；這裡補一道，防止通知漏掉時一路播下去。
                if let clip = self.clip, !self.clipFinished, self.isPlaying, self.currentTime >= clip.end {
                    self.finishClip()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                if self.clip != nil { self.clipFinished = true }
            }
        }
        // 檔案載入是非同步的。準備好之前跳轉可能被忽略，所以等狀態變成可播放再處理待播的請求。
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.itemStatusChanged() }
        }

        Task { [weak self] in
            let seconds = (try? await item.asset.load(.duration))?.seconds ?? 0
            guard let self, self.loadedURL == url else { return }
            self.duration = seconds.isFinite ? seconds : 0
        }
    }

    func unload() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let clipEndObserver, let player { player.removeTimeObserver(clipEndObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
        player?.pause()
        player = nil
        timeObserver = nil
        clipEndObserver = nil
        endObserver = nil
        statusObservation = nil
        loadedURL = nil
        pendingStart = nil
        seekGeneration += 1
        clip = nil
        clipFinished = false
        isPlaying = false
        hasStarted = false
        currentTime = 0
        duration = 0
    }

    /// 只播 start 到 end 這一段，播到 end 自動暫停。
    func playClip(from start: Double, to end: Double) {
        guard let player else { return }
        let start = max(0, start)
        // 時間軸偶爾會給出長度近乎零的句子，至少播 0.3 秒，不然按了像沒反應。
        let end = max(end, start + 0.3)
        setClip(Clip(start: start, end: end), on: player)
        begin(at: start)
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        if let clip {
            // 這句播完了：再按一次重播同一句。還沒播完（中途暫停）：從暫停處繼續播到句尾。
            if clipFinished || currentTime >= clip.end {
                playClip(from: clip.start, to: clip.end)
            } else {
                hasStarted = true
                player.play()
                isPlaying = true
            }
            return
        }
        // 還沒點過任何一句：從目前位置一路播下去；播完再按就從頭開始。
        if duration > 0, currentTime >= duration - 0.05 {
            begin(at: 0)
        } else {
            hasStarted = true
            player.play()
            isPlaying = true
        }
    }

    // MARK: - 內部

    private func setClip(_ newClip: Clip, on player: AVPlayer) {
        if let clipEndObserver { player.removeTimeObserver(clipEndObserver) }
        clip = newClip
        clipFinished = false
        // AVPlayer 正常播放經過句尾時會呼叫這個回呼，比每 0.1 秒檢查一次準。
        clipEndObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: newClip.end, preferredTimescale: 600))],
            queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated { self?.finishClip() }
        }
    }

    private func finishClip() {
        guard clip != nil, !clipFinished else { return }
        clipFinished = true
        player?.pause()
        isPlaying = false
    }

    /// 跳到指定秒數，跳轉完成後才開始播，避免先從舊位置（例如 0 秒）播出一小段。
    private func begin(at seconds: Double) {
        guard let player else { return }
        player.pause()
        currentTime = seconds
        hasStarted = true
        isPlaying = true
        seekGeneration += 1
        guard player.currentItem?.status == .readyToPlay else {
            pendingStart = seconds
            return
        }
        pendingStart = nil
        seek(player, to: seconds, generation: seekGeneration)
    }

    private func seek(_ player: AVPlayer, to seconds: Double, generation: Int) {
        // 用精確跳轉，避免壓縮格式跳到附近的關鍵幀而差個一兩秒。
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished, generation == self.seekGeneration, let player = self.player else { return }
                player.play()
            }
        }
    }

    private func itemStatusChanged() {
        guard let player, let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            guard let start = pendingStart else { return }
            pendingStart = nil
            seek(player, to: start, generation: seekGeneration)
        case .failed:
            pendingStart = nil
            isPlaying = false
        default:
            break
        }
    }
}
