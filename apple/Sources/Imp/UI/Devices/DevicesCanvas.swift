import ImpDesign
import ImpKit
import SwiftFlow
import SwiftUI

/// The picture of where every Imp is, as a canvas that pans, zooms and lets devices be moved: devices as cards with
/// their Imps inside, the channels between devices (solid on the local network, dashed through the Hop) and a thin
/// tether from an Imp to the device it thinks on. `DeviceGraph` decides what is on it; this draws it with SwiftFlow in
/// the app's look. It only reports what was pressed (`open`): the sheet is the screen's. Nothing on it is
/// selectable, connectable or deletable, so SwiftFlow's own keys (Delete, undo) never act on the map.
struct DevicesCanvas: View {
    let map: DeviceMap
    /// The Hop's address as set, so its node says whether it is off or needs an address.
    let hop: String
    /// Where devices were dragged to, kept by the router for the session.
    @Binding var moved: [String: CGPoint]
    let open: (DevicesSheet) -> Void
    /// Link a device, offered on the canvas while nothing is linked.
    let link: () -> Void

    @State private var flow = SwiftFlowInstance()
    @State private var hoveredNode: String?
    @State private var hoveredEdge: String?
    /// The canvas's size, and whether the person has panned or zoomed since it was last fitted: until then the
    /// canvas keeps the whole map in view as the window changes; after, a refresh of the link leaves the view alone.
    @State private var canvas: CGSize = .zero
    @State private var steered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let graph = DeviceGraph.build(map, hopText: hop, moved: moved)
        SwiftFlow(
            nodes: graph.nodes, edges: graph.edges,
            onNodesChange: { changes in
                for case .position(let id, let position) in changes where graph.nodes.first(where: { $0.id == id })?.parentId == nil {
                    moved[id] = CGPoint(x: position.x, y: position.y)
                }
            },
            nodesConnectable: false, elementsSelectable: false, panOnScroll: true, zoomOnScroll: false,
            backgroundVariant: .dots, theme: theme, colorMode: scheme == .dark ? .dark : .light,
            fitView: false,
            accessibilityConfig: AccessibilityConfig(announceSelectionChanges: false),
            onNodeClick: { node in if let sheet = graph.sheet(ofNode: node.id) { open(sheet) } },
            onEdgeClick: { edge in if let sheet = graph.sheet(ofEdge: edge.id) { open(sheet) } },
            onMoveStart: { _ in steered = true }, onInit: { fit(graph) },
            swiftFlowInstance: flow,
            onNodeMouseEnter: { hoveredNode = $0.id }, onNodeMouseLeave: { if hoveredNode == $0.id { hoveredNode = nil } },
            onEdgeMouseEnter: { hoveredEdge = $0.id }, onEdgeMouseLeave: { if hoveredEdge == $0.id { hoveredEdge = nil } },
            edgeContent: { edge, result in
                guard let data = edge.data else { return AnyView(EmptyView()) }
                return AnyView(DeviceEdgeDrawing(data: data, result: result, hovered: hoveredEdge == edge.id))
            },
            nodeContent: { node in
                switch node.data.role {
                case .device(let device): AnyView(DeviceNodeCard(id: node.id, node: device, hop: node.data.hop, hovered: hoveredNode == node.id))
                case .imp(let contact, let ours):
                    AnyView(DeviceImpChip(id: node.id, name: contact.name, hue: contact.hue, ours: ours, hovered: hoveredNode == node.id, help: node.data.label))
                }
            },
            overlay: { AnyView(controls(graph)) })
        // SwiftFlow's nodes are drawn without accessibility names of their own; the list below stands in for the
        // canvas, so every device, Imp and line can be read and opened.
        .accessibilityRepresentation {
            VStack {
                Text(verbatim: map.accessibilitySummary)
                ForEach(graph.openable) { item in
                    Button(item.label) { open(item.sheet) }
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            canvas = size
            if !steered { fit(graph) }
        }
        // A device or Imp came or went: show the whole map again.
        .onChange(of: graph.nodes.map(\.id)) { fit(graph) }
    }

    /// Link a device, centred at the bottom while nothing is linked, and the zoom controls, bottom leading. Both float
    /// over the canvas, so neither moves anything.
    private func controls(_ graph: DeviceGraph.Graph) -> some View {
        ZStack {
            zoomControls(graph)
            if !map.nodes.contains(where: \.isLinkedDevice) {
                Button(action: link) { FitLabel("settings.devices.link.title", systemImage: "qrcode") }
                    .buttonStyle(.primary)
                    .padding(Spacing.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func zoomControls(_ graph: DeviceGraph.Graph) -> some View {
        VStack(spacing: Spacing.hairline) {
            HoverIconButton(systemName: "plus", help: "devices.zoom_in", tint: Tone.text) { steered = true; flow.zoomIn() }
            HoverIconButton(systemName: "minus", help: "devices.zoom_out", tint: Tone.text) { steered = true; flow.zoomOut() }
            HoverIconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "devices.fit", tint: Tone.text) { fit(graph) }
        }
        .padding(Spacing.tight)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.surface)
            .overlay { RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.card) })
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// Shows the whole map, centred, from the devices' own frames (`DeviceViewport`), not from SwiftFlow's
    /// measuring, which comes later and not at all in a snapshot.
    private func fit(_ graph: DeviceGraph.Graph) {
        guard let viewport = DeviceViewport.fitting(graph, in: canvas) else { return }
        steered = false
        flow.setViewport(viewport, animated: false)
    }

    /// SwiftFlow's colours from the app's tokens: the window's surface, quiet dots, muted lines.
    private var theme: SwiftFlowTheme {
        SwiftFlowTheme(
            edgeColor: Tone.muted, edgeSelectedColor: Tone.accentBright, edgeWidth: Stroke.focus, edgeSelectedWidth: Stroke.focus,
            nodeBackgroundColor: Tone.card, nodeSelectedBorderColor: Tone.accentBright, nodeSelectedBorderWidth: 0,
            handleColor: .clear, handleBorderColor: .clear, handleSize: Stroke.hairline,
            canvasBackgroundColor: Tone.surface, gridColor: Tone.faint, gridSpacing: Spacing.wide,
            edgeLabelFont: Typeface.small, edgeLabelColor: Tone.muted, edgeLabelBackgroundColor: Tone.card)
    }
}
