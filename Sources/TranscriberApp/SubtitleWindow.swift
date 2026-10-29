import AppKit
import SwiftUI

/// 即時字幕的浮動視窗：永遠在最上層、全螢幕播放時也看得到、不搶走其他 App 的焦點，可以拖到任何位置。
@MainActor
final class SubtitleWindowController {
    private var panel: NSPanel?

    /// - Parameter translating: 有翻譯時視窗加高，多一行譯文。
    func show(model: AppModel, translating: Bool) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let size = NSSize(width: SubtitleView.width, height: SubtitleView.height(translating: translating))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: SubtitleView().environment(model))

        // 預設放在主螢幕下方置中，離底部 80 點，避開 Dock 與影片本身的控制列。
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 80))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// 沒翻譯時兩行：上一行是前一句（淡），下一行是正在說的話或最新一句。
/// 有翻譯時：原文一行（淡）、譯文兩行（ArchCross 黃），譯文是主角。
struct SubtitleView: View {
    @Environment(AppModel.self) private var model

    static let width: CGFloat = 820
    static func height(translating: Bool) -> CGFloat { translating ? 150 : 120 }

    /// ArchCross 品牌黃，與 App 圖示同色。
    private static let translationColor = Color(red: 0xFE / 255, green: 0xC1 / 255, blue: 0x49 / 255)

    var body: some View {
        let lines = model.subtitleLines
        let translating = model.isTranslatingLive
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                if translating {
                    Text(lines.current.isEmpty ? "等待聲音…" : lines.current)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(model.liveTranslationLine.isEmpty ? "（講完一句後出現譯文）" : model.liveTranslationLine)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(model.liveTranslationLine.isEmpty ? .white.opacity(0.35) : Self.translationColor)
                        .lineLimit(2)
                        .truncationMode(.head)
                } else {
                    Text(lines.previous)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(lines.current.isEmpty ? "等待聲音…" : lines.current)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(lines.current.isEmpty ? .white.opacity(0.4) : .white)
                        // 一句很長時保留最新的字，前面的用「…」省略。
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            Button(action: model.toggleLive) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("停止即時字幕")
            .padding(8)
        }
        .frame(width: Self.width, height: Self.height(translating: translating))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
    }
}
