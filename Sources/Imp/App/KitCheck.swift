import Foundation
import ImpKit

/// `Imp --check-kit <file.json>...`: runs kit files through the same parser the app uses, for the
/// community registry's CI. Nothing is added anywhere; it only reads and reports.
enum KitCheck {
    /// Prints one block per file; returns the process exit code (1 if any file failed or has a problem).
    static func run(files: [String]) -> Int32 {
        guard !files.isEmpty else {
            print("usage: Imp --check-kit <file.json>...")
            return 2
        }
        var failed = false
        for path in files {
            let name = (path as NSString).lastPathComponent
            guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
                print("FAIL \(name): can't read the file")
                failed = true
                continue
            }
            do {
                let kit = try Kit.parse(text)
                var errors = kit.problems
                // The declared format must be at least what the content needs, or an older Imp would misread it.
                if let declared = declaredVersion(text) {
                    if declared < kit.formatVersion {
                        errors.append("Says \"imp\": \(declared) but needs format \(kit.formatVersion) (it has Imps).")
                    }
                } else if kit.formatVersion > 0 {
                    errors.append("Missing \"imp\": the format version.")
                }
                let warnings = kit.warnings().map(\.text)
                print("\(errors.isEmpty ? "ok  " : "FAIL") \(name): \"\(kit.name)\" format \(kit.formatVersion), "
                      + "\(kit.imps.count) Imps, \(kit.triggers.count + kit.imps.reduce(0) { $0 + $1.triggers.count }) triggers, \(kit.servers.count) tools, \(kit.animations.count + kit.imps.reduce(0) { $0 + $1.animations.count }) animations")
                for e in errors { print("     problem: \(e)") }
                for w in warnings { print("     warning: \(w)") }
                if !errors.isEmpty { failed = true }
            } catch {
                print("FAIL \(name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    private static func declaredVersion(_ text: String) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return object["imp"] as? Int
    }
}
