import AppKit
import SwiftUI

/// 即時字幕的浮動視窗：永遠在最上層、全螢幕播放時也看得到、不搶走其他 App 的焦點，可以拖到任何位置。
@MainActor
final class SubtitleWindowController {
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?

    /// 使用者拖過字幕後的位置（視窗左下角，螢幕座標），下次開字幕放回同一個地方。
    private static let originKey = "subtitlePanelOrigin"

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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: SubtitleView().environment(model))

        if let origin = Self.savedOrigin(for: size) {
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main?.visibleFrame {
            // 預設放在主螢幕下方置中，離底部 80 點，避開 Dock 與影片本身的控制列。
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 80))
        }
        // 拖完就記下位置；程式自己設定位置時也會觸發，存下的就是目前位置，不影響結果。
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: Self.originKey)
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// 上次拖到的位置；那個位置已經不在任何螢幕上（例如外接螢幕拔掉了）就不用，改回預設位置。
    private static func savedOrigin(for size: NSSize) -> NSPoint? {
        guard let stored = UserDefaults.standard.string(forKey: originKey) else { return nil }
        let origin = NSPointFromString(stored)
        let frame = NSRect(origin: origin, size: size)
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersection(frame).width >= size.width / 2 }
        return visible ? origin : nil
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
            // 文字不接滑鼠，按在字上也是按到底下的拖曳區，整個字幕都能拖。
            .allowsHitTesting(false)
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
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.78))
                WindowDragArea()
            }
        )
    }
}

/// 字幕底下的透明拖曳區：按住拖動就移動整個字幕視窗。
/// 視窗內容是 SwiftUI，滑鼠事件會先被 SwiftUI 接走，視窗的 isMovableByWindowBackground 不會生效，
/// 所以用一個 AppKit 視圖接 mouseDown，交給系統的 performDrag 移動視窗。關閉鈕疊在它上面，照樣能按。
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
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
