import ImpDesign
import ImpKit
import SwiftUI

/// Saving every Imp to a file, bringing a kit in, and starting over.
struct BackupPane: View {
    @Bindable var model: AppModel
    let router: HomeRouter
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Card("settings.backup.keep.title", icon: "shippingbox.fill", info: "settings.backup.keep.info") {
                Row("settings.backup.export.title", icon: "square.and.arrow.up.fill") {
                    Button {
                        ImpExport.save(Set(model.prefs.imps.map(\.id)), model: model, name: String(localized: "All Imps"), fileName: String(localized: "Imps"), shared: true)
                    } label: { FitLabel("Export…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.imp(.secondary, small: true))
                }
                .settingAnchor(.backupExport)
                Row("settings.backup.import.title", icon: "square.and.arrow.down.on.square.fill") {
                    Button { router.kitFlow = KitFlow(imp: nil) } label: { FitLabel("Import…", systemImage: "square.and.arrow.down.on.square") }
                        .buttonStyle(.imp(.secondary, small: true))
                }
                .settingAnchor(.backupImport)
            }

            Card("settings.backup.reset.title", icon: "arrow.counterclockwise", info: "settings.backup.reset.info") {
                Row("app.reset", icon: "trash.fill") {
                    Button(role: .destructive) { confirmingReset = true } label: { FitLabel("Reset…", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.imp(.destructive, small: true))
                }
                .settingAnchor(.backupReset)
            }
        }
        .confirmationDialog("Erase everything and start over?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Erase and Restart", role: .destructive) { model.resetToFirstLaunch() }
        } message: {
            Text("Every Imp, service, key, tool, trigger, chat and setting is deleted. This can't be undone.")
        }
    }
}
