import Foundation
import CoreGraphics

/// Pure screen bounds calculation shared by the AppKit panel and headless checks.
public enum PanelGeometry {
    public static func bottomRightFrame(size: CGSize, of frame: CGRect) -> CGRect {
        CGRect(x: frame.maxX - size.width, y: frame.minY, width: size.width, height: size.height)
    }

    public static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height * 0.4)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.maxY - height, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }

    /// Reserve the expanded footprint even when collapsed, so hover never moves the mascot.
    public static func autoHideFrame(_ frame: CGRect, expandedWidth: CGFloat, in visible: CGRect) -> CGRect {
        let footprint = clamp(CGRect(x: frame.maxX - expandedWidth, y: frame.minY,
                                     width: expandedWidth, height: visible.height * 0.4), to: visible)
        let width = min(frame.width, footprint.width)
        return CGRect(x: footprint.maxX - width, y: footprint.minY,
                      width: width, height: min(frame.height, footprint.height))
    }
}
