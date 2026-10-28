import AppKit
import SwiftUI

@main
struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Lisvo", id: "main") {
            ContentView()
                .environment(model)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 760, height: 640)
        .commands {
            // 不放在「新增」位置：macOS 開檔或重新啟動 App 時會自動觸發「新增」，會意外跳出選檔視窗。
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .importExport) {
                Button("打開音檔…") { model.chooseInput() }
                    .keyboardShortcut("o")
                    .disabled(model.isRunning)
            }
        }
    }
}

/// 處理從 Finder「打開方式」或拖到 Dock 圖示送進來的檔案。
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel? {
        didSet {
            guard let model, let pending = pendingURL else { return }
            model.setInput(pending)
            pendingURL = nil
        }
    }

    /// App 還沒開好視窗前就收到檔案時先記著。
    @MainActor private var pendingURL: URL?

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: ContentView.isSupportedFile) else { return }
        if let model {
            model.setInput(url)
        } else {
            pendingURL = url
        }
        NSApp.activate()
    }

    /// 這不是文件型 App，啟動或點 Dock 圖示時不要建立「未命名文件」。
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
