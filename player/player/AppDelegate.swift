import UIKit

/// Bridges SwiftUI App lifecycle with UIKit orientation callbacks.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationManager.shared.supportedOrientations
    }
}

