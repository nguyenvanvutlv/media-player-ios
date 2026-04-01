import UIKit

#if os(tvOS)
@MainActor
final class OrientationManager {
    static let shared = OrientationManager()
    private init() {}

    func lock(to mask: UInt) {}
    func lockToPortrait() {}
    func lockToLandscape() {}
}
#else
@MainActor
final class OrientationManager {
    static let shared = OrientationManager()

    /// Orientation mask currently allowed by the app.
    /// `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` reads this value.
    private(set) var supportedOrientations: UIInterfaceOrientationMask = .portrait

    private init() {}

    func lock(to mask: UIInterfaceOrientationMask) {
        supportedOrientations = mask
        requestRotationUpdate(for: mask)
    }

    func lockToPortrait() {
        lock(to: .portrait)
    }

    func lockToLandscape() {
        lock(to: .landscape)
    }

    private func requestRotationUpdate(for mask: UIInterfaceOrientationMask) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })

        guard let scene else {
            return
        }

        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            UIViewController.attemptRotationToDeviceOrientation()
            return
        }

        // iOS 15 and earlier fallback. This is best-effort and may be ignored by the system.
        if mask.contains(.landscape) {
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
        } else if mask.contains(.portrait) {
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first(where: { $0.isKeyWindow })
    }
}

#endif
