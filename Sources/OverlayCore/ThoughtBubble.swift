import CoreGraphics

/// Scalloped thought cloud with two separate bubbles pointing towards the mascot.
public enum ThoughtBubble {
    public static let tailHeight: CGFloat = 18
    public static let opacity: CGFloat = 0.22

    public static func path(in bounds: CGRect, tailX: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard bounds.width > 0, bounds.height > tailHeight else { return path }
        let cloud = CGMutablePath()
        cloud.move(to: CGPoint(x: 0.13, y: 0.25))
        cloud.addCurve(to: CGPoint(x: 0.14, y: 0.72), control1: CGPoint(x: 0, y: 0.32), control2: CGPoint(x: 0, y: 0.65))
        cloud.addCurve(to: CGPoint(x: 0.38, y: 0.89), control1: CGPoint(x: 0.12, y: 1), control2: CGPoint(x: 0.32, y: 1))
        cloud.addCurve(to: CGPoint(x: 0.65, y: 0.90), control1: CGPoint(x: 0.42, y: 1), control2: CGPoint(x: 0.59, y: 1))
        cloud.addCurve(to: CGPoint(x: 0.88, y: 0.72), control1: CGPoint(x: 0.76, y: 1), control2: CGPoint(x: 0.91, y: 0.98))
        cloud.addCurve(to: CGPoint(x: 0.91, y: 0.28), control1: CGPoint(x: 1, y: 0.76), control2: CGPoint(x: 1, y: 0.31))
        cloud.addCurve(to: CGPoint(x: 0.68, y: 0.15), control1: CGPoint(x: 0.92, y: 0.08), control2: CGPoint(x: 0.77, y: 0.02))
        cloud.addCurve(to: CGPoint(x: 0.40, y: 0.15), control1: CGPoint(x: 0.62, y: 0), control2: CGPoint(x: 0.46, y: 0))
        cloud.addCurve(to: CGPoint(x: 0.13, y: 0.25), control1: CGPoint(x: 0.28, y: 0.02), control2: CGPoint(x: 0.12, y: 0.05))
        cloud.closeSubpath()
        path.addPath(cloud, transform: CGAffineTransform(a: bounds.width, b: 0, c: 0,
                                                        d: bounds.height - tailHeight,
                                                        tx: bounds.minX, ty: bounds.minY + tailHeight))
        let x = min(max(tailX, bounds.minX + 8), bounds.maxX - 8)
        path.addEllipse(in: CGRect(x: x + 3, y: bounds.minY + 1, width: 5, height: 5))
        path.addEllipse(in: CGRect(x: x - 3, y: bounds.minY + 8, width: 8, height: 8))
        return path
    }
}
