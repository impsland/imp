import AppKit
import SnapshotTesting
import Testing
@testable import Imp

/// The main screens in their key states, in the light and the dark appearance, against the reference
/// images in `__Snapshots__`. The scenes are fixed (see `DesignScene`), so a difference is a change in how
/// a screen looks. The references are tied to the macOS version they were recorded on (`Reference`).
@MainActor
@Suite("Screen snapshots", .serialized)
struct ScreenSnapshotTests {
    @Test("A main screen looks as it did", arguments: DesignScene.allCases, [false, true])
    func screen(_ scene: DesignScene, dark: Bool) throws {
        try Reference.check(scene, dark: dark)
    }
}

/// Where the references live and when they are compared.
@MainActor
enum Reference {
    /// The folder next to the tests that holds the images.
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__")
    /// The macOS major version the images were recorded on, stored next to them. Text and controls are
    /// drawn a little differently from one macOS to the next, so another major version does not compare
    /// (CI and a developer machine can differ). `make snapshots RECORD=1` records again.
    static let versionFile = folder.appendingPathComponent("recorded-on.txt")
    static let recording = ProcessInfo.processInfo.environment["IMP_SNAPSHOTS_RECORD"] == "1"
    static var osMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
    static var recordedMajor: Int? {
        (try? String(contentsOf: versionFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func check(_ scene: DesignScene, dark: Bool) throws {
        // English, so the words and the formats are the same on every machine.
        UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        let recorded = recordedMajor
        if !recording, let recorded, recorded != osMajor {
            print("Skipping \(scene.rawValue): the references were recorded on macOS \(recorded), this is macOS \(osMajor).")
            return
        }
        let rep = try #require(scene.image(dark: dark), "The screen could not be drawn.")
        let image = NSImage(size: scene.size)
        image.addRepresentation(rep)
        let name = dark ? "dark" : "light"
        let exists = FileManager.default.fileExists(atPath: folder.appendingPathComponent("ScreenSnapshotTests/\(scene.rawValue).\(name).png").path)
        if recording || !exists {
            // Recording is expected, so the library's note about it is not a failure.
            withKnownIssue("Recording a reference image.") {
                withSnapshotTesting(record: .all) { assertSnapshot(of: image, as: .image(precision: 0.99), named: name, testName: scene.rawValue) }
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "\(osMajor)\n".write(to: versionFile, atomically: true, encoding: .utf8)
        } else {
            assertSnapshot(of: image, as: .image(precision: 0.99), named: name, testName: scene.rawValue)
        }
    }
}
