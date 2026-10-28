import AVFoundation
import CoreMedia
import Foundation

public enum AudioNormalizerError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: "這個檔案裡沒有聲音軌。"
        case .readerFailed(let detail): "讀取音檔失敗：\(detail)"
        }
    }
}

/// 把任何音檔或影片的聲音轉成 16 kHz 單聲道 WAV。
/// 三個模型（Apple 辨識、Whisper、分講者）都讀同一份轉好的檔案，格式差異只在這裡處理一次。
public enum AudioNormalizer {
    public static let sampleRate: Double = 16_000

    public struct Output: Sendable {
        public let url: URL
        public let duration: Double
    }

    public static func normalize(_ source: URL, into directory: URL) async throws -> Output {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioNormalizerError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        // 多條聲音軌（例如影片的雙語軌）一併混成單聲道。
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: readerSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioNormalizerError.readerFailed("無法建立音訊輸出") }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioNormalizerError.readerFailed(reader.error?.localizedDescription ?? "未知原因")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("normalized-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw AudioNormalizerError.readerFailed("無法建立音訊格式")
        }
        let file = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        var totalFrames: Int64 = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
                  let channel = pcm.floatChannelData?[0]
            else { throw AudioNormalizerError.readerFailed("無法配置音訊緩衝區") }

            let byteCount = frameCount * MemoryLayout<Float>.size
            let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: channel)
            guard status == kCMBlockBufferNoErr else { throw AudioNormalizerError.readerFailed("複製音訊資料失敗（\(status)）") }
            pcm.frameLength = AVAudioFrameCount(frameCount)
            try file.write(from: pcm)
            totalFrames += Int64(frameCount)
        }

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: destination)
            throw AudioNormalizerError.readerFailed(reader.error?.localizedDescription ?? "未知原因")
        }
        guard totalFrames > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw AudioNormalizerError.noAudioTrack
        }
        return Output(url: destination, duration: Double(totalFrames) / sampleRate)
    }
}
