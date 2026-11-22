import ImpDesign
import SwiftUI

/// What kind of tool a switch is: one of the Imp's own groups (or the commands tool), or a tool server that was added.
enum ToolKind: CaseIterable {
    case builtIn, server

    /// A tool server's id starts with `mcp.` (`DeviceToolLimits.groupID(server:)`), everything else is built in.
    init(id: String) { self = id.hasPrefix("mcp.") ? .server : .builtIn }

    var title: LocalizedStringKey {
        switch self {
        case .builtIn: "devices.tools.built_in"
        case .server: "devices.tools.servers"
        }
    }

    var symbol: String {
        switch self {
        case .builtIn: "wrench.and.screwdriver.fill"
        case .server: "puzzlepiece.extension.fill"
        }
    }
}

/// One tool's switch: its picture, name and whether it is on.
struct ToolItem: Identifiable, Equatable {
    var id: String
    var symbol: String
    var title: String
    var on: Bool

    var kind: ToolKind { ToolKind(id: id) }
}

/// The tools of one kind, with how many of them are on.
struct ToolSection: Identifiable, Equatable {
    var kind: ToolKind
    var items: [ToolItem]

    var id: String { "\(kind)" }
    var onCount: Int { items.filter(\.on).count }
    var allOn: Bool { onCount == items.count }

    /// The tools grouped by kind, built in first, in the order given. A kind with no tools has no section.
    static func sections(of items: [ToolItem]) -> [ToolSection] {
        ToolKind.allCases.compactMap { kind in
            let own = items.filter { $0.kind == kind }
            return own.isEmpty ? nil : ToolSection(kind: kind, items: own)
        }
    }
}

/// Tools as switches that read at a glance: grouped by kind, each group with its name, how many are on and one control
/// to switch the group, and under it the tools as chips that are filled with the app's tint while on and quiet while off. Pressing a chip
/// switches that tool. `change` is called with the ids to switch and whether they should now be on.
struct ToolGrid: View {
    let items: [ToolItem]
    let change: ([String], Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            ForEach(ToolSection.sections(of: items)) { section in
                VStack(alignment: .leading, spacing: Spacing.small) {
                    header(section)
                    FlowLayout(spacing: Spacing.small, lineSpacing: Spacing.small) {
                        ForEach(section.items) { item in
                            ToolChip(item: item) { change([item.id], !item.on) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The kind's name and count, and the one control that switches all of its tools (when there is more than one).
    private func header(_ section: ToolSection) -> some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: section.kind.symbol).font(.icon(.tiny)).foregroundStyle(Tone.muted).accessibilityHidden(true)
            Text(section.kind.title).font(Typeface.small).foregroundStyle(Tone.muted)
            Text(verbatim: "\(section.onCount)/\(section.items.count)").font(Typeface.small.monospacedDigit()).foregroundStyle(Tone.faint)
            Spacer(minLength: 0)
            if section.items.count > 1 {
                Button { change(section.items.map(\.id), !section.allOn) } label: {
                    Image(systemName: section.allOn ? "minus.circle" : "checkmark.circle").font(.icon(.small)).foregroundStyle(Tone.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerStyle(.link)
                .help(section.allOn ? "devices.tools.all_off" : "devices.tools.all_on")
                .accessibilityLabel(Text(section.allOn ? "devices.tools.all_off" : "devices.tools.all_on"))
            }
        }
    }
}

/// One tool: filled with the app's tint and in full ink while on, quiet while off. A toggle for a screen reader.
private struct ToolChip: View {
    let item: ToolItem
    let toggle: () -> Void
    @Environment(\.impTint) private var tint

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Spacing.snug) {
                Image(systemName: item.symbol).font(.icon(.tiny))
                Text(verbatim: item.title).font(Typeface.label).lineLimit(1)
            }
            .foregroundStyle(item.on ? Tone.text : Tone.faint)
            .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.snug)
            .background(Capsule().fill(item.on ? AnyShapeStyle(tint.opacity(Opacity.tintFillStrong)) : AnyShapeStyle(Tone.surface)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .impAnimation(ImpDesign.Motion.quick, value: item.on)
        .help(item.title)
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityValue(Text(item.on ? "devices.tool.on" : "devices.tool.off"))
        .accessibilityAddTraits(.isToggle)
    }
}
