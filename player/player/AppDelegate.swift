import UIKit

/// Bridges SwiftUI App lifecycle with UIKit orientation callbacks.
final class AppDelegate: NSObject, UIApplicationDelegate {
#if os(tvOS)
#else
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationManager.shared.supportedOrientations
    }
#endif
}

