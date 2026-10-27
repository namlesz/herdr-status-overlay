import Foundation
import CoreGraphics

/// Pure screen bounds calculation shared by the AppKit panel and headless checks.
public enum PanelGeometry {
    public static func anchoredFrame(size: CGSize, of frame: CGRect, direction: PanelDirection) -> CGRect {
        CGRect(x: direction.extendsLeft ? frame.maxX - size.width : frame.minX,
               y: direction.extendsUp ? frame.minY : frame.maxY - size.height,
               width: size.width, height: size.height)
    }

    public static func bottomRightFrame(size: CGSize, of frame: CGRect) -> CGRect {
        anchoredFrame(size: size, of: frame, direction: .topLeft)
    }

    public static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height * 0.4)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.maxY - height, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }

    /// Reserve the expanded footprint even when collapsed, so hover never moves the mascot.
    public static func autoHideFrame(_ frame: CGRect, expandedWidth: CGFloat,
                                     direction: PanelDirection = .topLeft,
                                     in visible: CGRect) -> CGRect {
        let size = CGSize(width: min(expandedWidth, visible.width), height: visible.height * 0.4)
        let footprint = clamp(anchoredFrame(size: size, of: frame, direction: direction), to: visible)
        return anchoredFrame(size: CGSize(width: min(frame.width, footprint.width),
                                          height: min(frame.height, footprint.height)),
                             of: footprint, direction: direction)
    }
}
