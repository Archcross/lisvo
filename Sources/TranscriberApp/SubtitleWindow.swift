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

/// 字幕從底部往上滾：文字完整排版，只露出最後幾行，舊的從上緣捲出去，不用「…」省略。
/// 沒翻譯時：原文三行。有翻譯時：原文一行（淡）、譯文兩行（ArchCross 黃），譯文是主角。
struct SubtitleView: View {
    @Environment(AppModel.self) private var model

    static let width: CGFloat = 820
    static func height(translating: Bool) -> CGFloat { translating ? 150 : 140 }

    /// ArchCross 品牌黃，與 App 圖示同色。
    private static let translationColor = Color(red: 0xFE / 255, green: 0xC1 / 255, blue: 0x49 / 255)

    var body: some View {
        let source = model.subtitleSourceText
        let translating = model.isTranslatingLive
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                if translating {
                    RollingText(
                        text: source.isEmpty ? "等待聲音…" : source,
                        size: 18, weight: .medium, lines: 1,
                        color: .white.opacity(0.6)
                    )
                    let translation = model.translationNotice.isEmpty ? model.liveTranslationText : model.translationNotice
                    RollingText(
                        text: translation.isEmpty ? "（開始說話後出現譯文）" : translation,
                        size: 26, weight: .semibold, lines: 2,
                        color: model.liveTranslationText.isEmpty ? .white.opacity(0.35) : Self.translationColor
                    )
                } else {
                    RollingText(
                        text: source.isEmpty ? "等待聲音…" : source,
                        size: 26, weight: .semibold, lines: 3,
                        color: source.isEmpty ? .white.opacity(0.4) : .white
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, 22)
            // 右上角留給關閉鈕，文字不要壓到它。
            .padding(.trailing, 14)
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

/// 固定幾行高的字幕區：文字照寬度完整換行，貼齊底部，超出的上半部被裁掉。
/// 新字出現在最後一行，換行時整段往上推一行，最上面那行捲出去。
struct RollingText: View {
    let text: String
    let size: CGFloat
    let weight: NSFont.Weight
    let lines: Int
    let color: Color

    var body: some View {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        // 用 AppKit 的行高算區塊高度，剛好露出整數行。
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        Text(text)
            .font(Font(font))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: lineHeight * CGFloat(lines), alignment: .bottom)
            .clipped()
            // 上緣淡出幾點：行高和實際排版差一點點時，被切到的那行不會看起來像破圖。
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 4)
                    Rectangle()
                }
            )
    }
}
