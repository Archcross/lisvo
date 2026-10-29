import AppKit
import SwiftUI

/// 即時字幕的浮動視窗：永遠在最上層、全螢幕播放時也看得到、不搶走其他 App 的焦點，可以拖到任何位置。
@MainActor
final class SubtitleWindowController {
    private var panel: NSPanel?

    func show(model: AppModel) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let size = NSSize(width: 820, height: 120)
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

/// 兩行字幕：上一行是前一句（淡），下一行是正在說的話或最新一句。
struct SubtitleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lines = model.subtitleLines
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
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
        .frame(width: 820, height: 120)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
    }
}
