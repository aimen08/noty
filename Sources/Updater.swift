import AppKit

#if canImport(Sparkle)
import Sparkle

/// Sparkle updater. This is the app's only network activity: it fetches the
/// appcast named by SUFeedURL, and nothing else. Turn it off in the pill's menu.
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// The deck is an accessory app, so raise it before Sparkle shows a window.
    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    static let available = true
}

#else

/// Built without the Sparkle framework — `./scripts/fetch-sparkle.sh` adds it.
final class Updater {
    static let shared = Updater()
    private init() {}

    var automaticallyChecks: Bool {
        get { false }
        set { _ = newValue }
    }
    func checkForUpdates() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "В этой сборке обновления недоступны"
        a.informativeText = "Эта копия Noty собрана без фреймворка Sparkle. "
            + "Запустите ./scripts/fetch-sparkle.sh и пересоберите приложение, чтобы включить автообновления."
        a.runModal()
    }

    static let available = false
}

#endif
