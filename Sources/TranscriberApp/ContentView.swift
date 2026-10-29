import AppKit
import SwiftUI
import TranscriberCore
import Translation
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(16)
            transcript
            statusBar
        }
        // 上方一列要放得下：模式、語言、講者、潤飾、開始轉錄（約 600 點），再窄會擠壓換行。
        .frame(minWidth: 660, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: SupportedMedia.isSupported) else { return false }
            model.setInput(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        // 即時翻譯的語言包還沒下載時，由這裡跳出系統的下載提示。
        .translationTask(model.translationDownloadRequest) { session in
            await LiveTranslator.prepareDownload(LiveTranslator.SessionBox(session))
            await model.translationDownloadFinished()
        }
    }

    // MARK: - 上方：輸入、輸出、選項

    private var controls: some View {
        @Bindable var model = model
        return VStack(spacing: 8) {
            PathRow(
                symbol: model.isLive ? model.liveAudioInUse.symbol : "waveform",
                title: "音檔",
                value: model.isLive ? "\(model.liveAudioInUse.label)（即時字幕）" : model.inputURL?.lastPathComponent,
                placeholder: "拖曳音檔或影片到視窗，或點這裡選擇",
                highlighted: isDropTargeted,
                action: model.chooseInput
            )
            .disabled(model.isRunning)
            // 手機傳來的音檔，逐字稿固定存到 iCloud；這時點這一列是打開 iCloud 資料夾，不是改設定。
            PathRow(
                symbol: model.inputFromInbox ? "icloud" : "folder",
                title: "輸出",
                value: model.activeOutputDisplayPath,
                placeholder: "",
                highlighted: false,
                action: model.inputFromInbox ? model.revealOutputDirectory : model.chooseOutputDirectory,
                trailing: AnyView(
                    Button(action: model.revealOutputDirectory) {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless)
                    .help("在 Finder 打開輸出資料夾")
                )
            )
            .disabled(model.isRunning)

            HStack(spacing: 12) {
                Group {
                Picker("模式", selection: $model.mode) {
                    ForEach(EngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                .help("快速：Mac 內建辨識。精準：Whisper 模型。")

                Picker("語言", selection: $model.language) {
                    ForEach(model.languageOptions) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()

                Picker("講者", selection: $model.speakerChoice) {
                    ForEach(SpeakerChoice.options, id: \.self) { Text(SpeakerChoice.label($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()

                Toggle("AI 潤飾", isOn: $model.polish)
                    .toggleStyle(.checkbox)
                    .help("用 Mac 內建 AI 修錯字、補標點、刪口頭禪。另存一份，原文不變。")
                }
                .disabled(model.isRunning || model.isLive)

                Spacer(minLength: 0)

                if model.isRunning {
                    Button("停止", role: .cancel, action: model.stop)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("開始轉錄", action: model.start)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canStart)
                }
            }

            liveRow
        }
    }

    /// 即時字幕自成一列：聽哪裡的聲音、什麼語言、要不要翻譯，跟上面的檔案轉錄設定分開。
    private var liveRow: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Image(systemName: "captions.bubble")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text("即時字幕")
                .foregroundStyle(.secondary)
            Group {
                Picker("來源", selection: $model.liveAudio) {
                    ForEach(LiveAudioSource.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("電腦聲音：網頁、影片、線上會議。麥克風：現場演講、面對面談話。")
                Text("聽").foregroundStyle(.secondary)
                Picker("聽", selection: $model.liveSource) {
                    ForEach(AppModel.liveSourceOptions) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("說話的語言。Mac 內建即時辨識不能自動偵測，要先選。")
                Text("譯成").foregroundStyle(.secondary)
                Picker("譯成", selection: $model.liveTranslation) {
                    ForEach(model.liveTranslationOptions) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("用 Mac 內建翻譯在本機翻譯；第一次用某組語言時會請你下載語言包。")
            }
            .disabled(model.isLive || model.isRunning)
            Spacer(minLength: 0)
            if model.isLive {
                Button("停止字幕", role: .cancel, action: model.toggleLive)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isStartingLive)
            } else {
                Button("開始字幕", action: model.toggleLive)
                    .disabled(model.isRunning)
                    .help(model.liveAudio.help)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - 中間：逐字稿

    private var transcript: some View {
        TranscriptList(
            segments: model.segments,
            isFinal: model.isFinalized,
            // 即時字幕時也算「進行中」：顯示等待提示、新句子出現時自動捲到底。
            isRunning: model.isRunning || model.isLive,
            hasInput: model.inputURL != nil || model.isLive,
            activeID: model.activeSegmentID,
            onSelect: model.play
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - 下方：狀態

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.playback.isLoaded {
                PlaybackControls(playback: model.playback)
            }
            if model.currentInboxFile != nil {
                Label("手機傳來", systemImage: "iphone")
                    .foregroundStyle(.secondary)
            }
            if model.isRunning {
                if let progress = model.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text(model.stageText)
                    .foregroundStyle(.secondary)
                if !model.sideStageText.isEmpty {
                    Text("· \(model.sideStageText)")
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(model.notices, id: \.self) { notice in
                Text(notice).foregroundStyle(.orange)
            }
            if !model.inboxQueue.isEmpty {
                Text("還有 \(model.inboxQueue.count) 個手機音檔待轉")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if case .finished = model.phase {
                Button("在 Finder 顯示", action: model.revealResult)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 40)
    }
}

/// 一行「圖示 標題 內容」，整行可以點。沒有外框，只用淡底色區分。
struct PathRow: View {
    let symbol: String
    let title: String
    let value: String?
    let placeholder: String
    let highlighted: Bool
    let action: () -> Void
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            Text(value ?? placeholder)
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing { trailing }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(highlighted ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

struct TranscriptList: View {
    let segments: [TranscriptSegment]
    let isFinal: Bool
    let isRunning: Bool
    let hasInput: Bool
    /// 正在播放的那一句，標上底色。
    let activeID: UUID?
    let onSelect: (TranscriptSegment) -> Void

    var body: some View {
        if segments.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: hasInput ? "text.alignleft" : "arrow.down.doc")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(isRunning ? "辨識出來的文字會出現在這裡" : (hasInput ? "按「開始轉錄」" : "拖曳音檔到這裡"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(segments) { segment in
                    SegmentRow(segment: segment, isActive: segment.id == activeID)
                        .id(segment.id)
                        .contentShape(Rectangle())
                        // 點一下只播這一句，播到句尾自動停。
                        .onTapGesture { onSelect(segment) }
                        .contextMenu {
                            Button("播放這句") { onSelect(segment) }
                            Button("拷貝這句") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(segment.text, forType: .string)
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(segment.id == activeID ? Color.accentColor.opacity(0.16) : Color.clear)
                                .padding(.horizontal, 6)
                        )
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: segments.count) {
                    // 轉錄中自動捲到最新一句。
                    guard isRunning, !isFinal, let last = segments.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let isActive: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Exporter.clock(segment.start))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(isActive ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            // 快速模式轉錄中還沒有講者，等分講者完成才補上；精準模式一開始就有。
            if let speaker = segment.speaker {
                Text(speaker)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(SpeakerPalette.color(for: speaker))
                    .frame(width: 56, alignment: .leading)
            }
            // 不開文字選取：選取會吃掉點擊，點句子播放就失效。要拷貝用右鍵「拷貝這句」或匯出檔。
            Text(segment.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

/// 底部的播放／暫停與時間。空白鍵也能播放／暫停。
struct PlaybackControls: View {
    let playback: AudioPlayback

    var body: some View {
        HStack(spacing: 8) {
            Button(action: playback.togglePlayPause) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .help(playback.isPlaying ? "暫停（空白鍵）" : (playback.clip == nil ? "播放（空白鍵）；點逐字稿的某一句就只播那句" : "重播或繼續播這一句（空白鍵）"))

            Text("\(Exporter.clock(playback.currentTime)) / \(Exporter.clock(playback.duration))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

enum SpeakerPalette {
    static let colors: [Color] = [
        Color(red: 0.75, green: 0.38, blue: 0.27),
        Color(red: 0.16, green: 0.47, blue: 0.50),
        Color(red: 0.42, green: 0.36, blue: 0.64),
        Color(red: 0.55, green: 0.48, blue: 0.20),
        Color(red: 0.62, green: 0.30, blue: 0.48),
        Color(red: 0.25, green: 0.45, blue: 0.30),
    ]

    /// 「講者 3」取數字決定顏色，同一位講者在整份逐字稿顏色一致。
    static func color(for speaker: String) -> Color {
        let number = Int(speaker.filter(\.isNumber)) ?? 1
        return colors[(max(1, number) - 1) % colors.count]
    }
}
