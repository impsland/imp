import CoreGraphics
import ImpDesign
import SwiftFlow

/// Where the Devices canvas looks. The layout is ours, so every device's frame is known without waiting for the
/// canvas to measure its nodes. The first view is computed from those frames and is the same on every run.
enum DeviceViewport {
    /// Space kept free around the graph.
    static let padding: CGFloat = Spacing.vast
    /// A map is never blown up past a little over life size, and never shrunk past where text is unreadable anyway.
    static let zoomRange: ClosedRange<CGFloat> = 0.2...1.2

    /// The viewport that shows `bounds` (flow coordinates) whole and centred in a canvas of `canvas`, or nil when
    /// there is nothing to show or the canvas has no size yet.
    static func fitting(_ bounds: CGRect, in canvas: CGSize, padding: CGFloat = padding, zoom: ClosedRange<CGFloat> = zoomRange) -> Viewport? {
        guard bounds.width > 0, bounds.height > 0, canvas.width > 0, canvas.height > 0 else { return nil }
        return getViewportForBounds(bounds: bounds, viewportSize: canvas, minZoom: zoom.lowerBound, maxZoom: zoom.upperBound, padding: padding)
    }

    /// The viewport that shows every device of `graph` (their Imps are inside them).
    static func fitting(_ graph: DeviceGraph.Graph, in canvas: CGSize) -> Viewport? {
        fitting(getNodesBounds(nodes: graph.devices, nodeSizes: graph.sizes), in: canvas)
    }
}
