import Foundation
import ImpKit

/// The iPhone's own `.agents` folder: its skills and custom commands (`docs/apps/skills-commands.md`). The phone has
/// no `~/.agents`, so the folder is `.agents` in the app's Documents (which the Files app and Finder show, since
/// the app shares them), read through the same core functions as the Mac's. There is no shell on the phone and no
/// folder of the person's to read: a command's text can read only files inside this one.
enum PhoneLibrary {
    /// Where `.agents` is: the app's Documents folder.
    static let home = URL.documentsDirectory

    static let shared = AgentLibrary(configDir: URL.applicationSupportDirectory.appending(path: "config"), homeDir: home)

    /// The folders a person puts skills and commands in, made so they are there to find.
    static func prepareFolders() {
        for name in ["skills", "commands"] {
            try? FileManager.default.createDirectory(at: home.appending(path: ".agents/\(name)"), withIntermediateDirectories: true)
        }
    }

    /// The shell and the files of a command's text on the phone.
    struct World: CommandWorld {
        func shell(_ line: String) async throws -> String { throw noShell(line) }

        /// A file of the Documents folder (`~/` or a relative path). Anything else names no file, so the word stays.
        func read(_ path: String) async throws -> String? {
            let relative = path.hasPrefix("~/") ? String(path.dropFirst(2)) : path
            let url = PhoneLibrary.home.appending(path: relative).standardizedFileURL
            guard url.path.hasPrefix(PhoneLibrary.home.standardizedFileURL.path + "/"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            do {
                return String(decoding: try Data(contentsOf: url), as: UTF8.self)
            } catch {
                throw CommandFailure(String(localized: "\(path) could not be read: \(error.localizedDescription)"))
            }
        }
    }
}
