import Foundation
import CoreGraphics

/// Pure screen bounds calculation shared by the AppKit panel and headless checks.
public enum PanelGeometry {
    public static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height * 0.4)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.maxY - height, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }
}
