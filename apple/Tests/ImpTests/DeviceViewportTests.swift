import CoreGraphics
import Foundation
import ImpKit
import SwiftFlow
import Testing
@testable import Imp

/// The first view of the Devices canvas: pure arithmetic from the devices' frames and the canvas's size.
@Suite struct DeviceViewportTests {
    private let canvas = CGSize(width: 1000, height: 600)
    private let pad = DeviceViewport.padding

    /// Where a flow rectangle lands on screen under a viewport.
    private func onScreen(_ rect: CGRect, _ viewport: Viewport) -> CGRect {
        CGRect(x: rect.minX * viewport.zoom + viewport.x, y: rect.minY * viewport.zoom + viewport.y,
               width: rect.width * viewport.zoom, height: rect.height * viewport.zoom)
    }

    @Test func aWideGraphIsShrunkToFitWithPaddingAndCentred() throws {
        let bounds = CGRect(x: 0, y: 0, width: 2000, height: 400)
        let viewport = try #require(DeviceViewport.fitting(bounds, in: canvas))
        let shown = onScreen(bounds, viewport)
        #expect(abs(viewport.zoom - (canvas.width - 2 * pad) / 2000) < 1e-9)
        #expect(abs(shown.minX - pad) < 1e-6 && abs(shown.maxX - (canvas.width - pad)) < 1e-6)
        #expect(abs(shown.midY - canvas.height / 2) < 1e-6)
    }

    @Test func aSmallGraphIsNotBlownUpPastTheLargestZoomAndStaysCentred() throws {
        let bounds = CGRect(x: 300, y: -50, width: 100, height: 80)
        let viewport = try #require(DeviceViewport.fitting(bounds, in: canvas))
        #expect(viewport.zoom == DeviceViewport.zoomRange.upperBound)
        let shown = onScreen(bounds, viewport)
        #expect(abs(shown.midX - canvas.width / 2) < 1e-6 && abs(shown.midY - canvas.height / 2) < 1e-6)
    }

    @Test func aHugeGraphIsNotShrunkPastTheSmallestZoom() throws {
        let viewport = try #require(DeviceViewport.fitting(CGRect(x: 0, y: 0, width: 100_000, height: 100_000), in: canvas))
        #expect(viewport.zoom == DeviceViewport.zoomRange.lowerBound)
    }

    @Test func nothingToShowOrNoCanvasYetGivesNoViewport() {
        #expect(DeviceViewport.fitting(.zero, in: canvas) == nil)
        #expect(DeviceViewport.fitting(CGRect(x: 0, y: 0, width: 100, height: 100), in: .zero) == nil)
    }

    @Test func aGraphOfLinkedDevicesIsWhollyInsideTheCanvas() throws {
        let phone = DeviceMap.Peer(id: UUID(), name: "Anna's iPhone", kind: .phone, reach: .direct, isTrusted: true)
        let studio = DeviceMap.Peer(id: UUID(), name: "Studio Mac", kind: .mac, reach: .viaServer, isTrusted: true)
        let map = DeviceMap.build(thisMac: "Mac", peers: [phone, studio], server: "hop.example.org:4677", imps: [], mcpServers: [], visitors: [])
        let graph = DeviceGraph.build(map)
        let viewport = try #require(DeviceViewport.fitting(graph, in: canvas))
        let bounds = getNodesBounds(nodes: graph.devices, nodeSizes: graph.sizes)
        let shown = onScreen(bounds, viewport)
        #expect(CGRect(origin: .zero, size: canvas).contains(shown))
        #expect(abs(shown.midX - canvas.width / 2) < 1e-6)
    }
}
