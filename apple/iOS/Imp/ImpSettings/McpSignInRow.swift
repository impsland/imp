import ImpDesign
import ImpKit
import SwiftUI

/// Under a tool server's address: "Sign in" opens the server's own sign-in page (the system's web
/// sheet, a private session) and "Sign out" forgets it. Works for any MCP server that asks for it. The
/// token is kept in the app-private file (`MCPAuthStore.standard`), never in the Keychain: the iPhone
/// has no "keys in the Keychain" setting, and the token is not a header the Imp carries to other devices.
struct McpSignInRow: View {
    let url: String
    @State private var signedIn = false
    @State private var working = false
    @State private var problem: String?
    @State private var presenter = WebAuthPresenter()

    private var address: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        if URL(string: address)?.host != nil {
            VStack(alignment: .leading, spacing: Spacing.small) {
                if signedIn {
                    Button { Task { await signOut() } } label: { Text("tools.mcp_sign_out") }.buttonStyle(.secondary).disabled(working)
                } else {
                    Button { Task { await signIn() } } label: { Text("tools.mcp_sign_in") }.buttonStyle(.secondary).disabled(working)
                }
                if let problem { Text(verbatim: problem).font(Typeface.small).foregroundStyle(Tone.danger) }
            }
            .task(id: address) { signedIn = MCPAuthStore.standard.hasAuth(for: address) }
        }
    }

    private func signIn() async {
        working = true; problem = nil
        defer { working = false; signedIn = MCPAuthStore.standard.hasAuth(for: address) }
        do { try await MCPSignIn(presenter: presenter).signIn(to: address) }
        catch MCPSignInError.cancelled {}
        catch { problem = error.localizedDescription }
    }

    private func signOut() async {
        working = true
        await MCPSignIn(presenter: presenter).signOut(of: address)
        working = false; signedIn = MCPAuthStore.standard.hasAuth(for: address)
    }
}
