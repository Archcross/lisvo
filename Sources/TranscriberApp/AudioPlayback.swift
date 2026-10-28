import AVFoundation
import Foundation
import Observation

/// 播放原始音檔（或影片的聲音），讓使用者點逐字稿的某句就從那裡開始聽。
@MainActor
@Observable
final class AudioPlayback {
    private(set) var isPlaying = false
    /// 目前播到第幾秒。
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// 載入後還沒播過時為 false，這時不標亮任何一句。
    private(set) var hasStarted = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadedURL: URL?

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
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }

        Task { [weak self] in
            let seconds = (try? await item.asset.load(.duration))?.seconds ?? 0
            guard let self, self.loadedURL == url else { return }
            self.duration = seconds.isFinite ? seconds : 0
        }
    }

    func unload() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player?.pause()
        player = nil
        timeObserver = nil
        endObserver = nil
        loadedURL = nil
        isPlaying = false
        hasStarted = false
        currentTime = 0
        duration = 0
    }

    /// 跳到指定秒數並開始播放。用精確跳轉，避免壓縮格式跳到附近的關鍵幀而差個一兩秒。
    func play(from seconds: Double) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        currentTime = max(0, seconds)
        hasStarted = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlaying = true
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // 播完後再按播放，從頭開始。
            if duration > 0, currentTime >= duration - 0.05 {
                play(from: 0)
            } else {
                hasStarted = true
                player.play()
                isPlaying = true
            }
        }
    }
}
