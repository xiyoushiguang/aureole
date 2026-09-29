import AppKit

/// Where the notch (or a virtual stand-in) sits on a screen, in AppKit screen coordinates.
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let notchRect: CGRect
    let hasHardwareNotch: Bool

    static let placeholder = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                           notchRect: CGRect(x: 663, y: 950, width: 185, height: 32),
                                           hasHardwareNotch: true)

    static func detect(on screen: NSScreen?) -> NotchGeometry {
        guard let screen else { return placeholder }
        let frame = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
            let rect = CGRect(x: left.maxX, y: frame.maxY - top, width: right.minX - left.maxX, height: top)
            return NotchGeometry(screenFrame: frame, notchRect: rect, hasHardwareNotch: true)
        }
        let height = max(24, NSStatusBar.system.thickness)
        let width: CGFloat = 180
        let rect = CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
        return NotchGeometry(screenFrame: frame, notchRect: rect, hasHardwareNotch: false)
    }
}
