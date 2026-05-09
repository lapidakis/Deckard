import Foundation
import Sparkle

/// Wraps `SPUStandardUpdaterController` so SwiftUI views can call
/// `checkForUpdates()` and bind a "can check" disabled state.
///
/// Configuration lives in the app bundle's Info.plist:
/// - `SUFeedURL` — appcast.xml location (HTTPS-only).
/// - `SUPublicEDKey` — base-64 EdDSA public key.
/// - `SUEnableAutomaticChecks` — false in v1.x. The user explicitly
///   triggers checks via the menubar item until the update channel
///   has earned the trust to run on a timer.
///
/// The matching private key is held by Mike (and the GitHub Actions
/// `APPCAST_ED_PRIVATE_KEY` secret); see `docs/operations.md` for the
/// one-time generate-and-publish flow.
@MainActor
final class AppUpdater: ObservableObject {
    let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates: Bool = false

    init() {
        // `startingUpdater: true` boots the Sparkle scheduler immediately;
        // with `SUEnableAutomaticChecks=false` in Info.plist this just means
        // the controller is ready to accept manual checks — no background
        // polling happens until the user opts in.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // The updater can refuse checks while one is in flight; mirror that
        // into a published flag so the menu item disables itself.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
