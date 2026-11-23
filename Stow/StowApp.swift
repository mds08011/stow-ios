import SwiftUI
import UIKit

@main
struct StowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RecordView()
                .environmentObject(model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        // Uploads may have finished, and the timer was asleep, while
                        // Stow was in the background or the phone was locked.
                        model.reload()
                        model.recorder.refreshElapsed()
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {

    /// iOS relaunches Stow in the background when an upload finishes. Recreating the
    /// session with the same identifier is what delivers the waiting events, and the
    /// completion handler tells iOS when they have all been handled.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == UploadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        UploadManager.shared.backgroundCompletionHandler = completionHandler
        UploadManager.shared.start()
    }
}
