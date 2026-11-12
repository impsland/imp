import Foundation
import Testing

/// The phone's heat is decided by what keeps drawing. Nothing in the iPhone app may start a loop of its
/// own: every continuous animation goes through `PacedTimeline` / `FramePolicy`, which pause it when the
/// scene is inactive, the view is covered, the picture is still, the phone saves power or Reduce Motion is on.
@Suite struct PhoneEnergyAuditTests {
    private static let phone = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("iOS/Imp")

    /// What may not appear in the iPhone app's sources.
    private static let forbidden = ["repeatForever", "CADisplayLink", "TimelineView(.animation", "Timer.scheduledTimer", "Timer.publish"]

    /// File name -> the forbidden thing it may contain, and why. Empty: nothing needs an exception.
    private static let allowed: [String: (token: String, reason: String)] = [:]

    private static func sources() -> [URL] {
        let walker = FileManager.default.enumerator(at: phone, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    @Test func theSourcesAreFound() {
        #expect(Self.sources().count > 20)
    }

    @Test func noFileStartsALoopOutsideThePolicy() throws {
        for file in Self.sources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbidden where text.contains(token) {
                let exception = Self.allowed[file.lastPathComponent]
                #expect(exception?.token == token && !(exception?.reason.isEmpty ?? true),
                        "\(file.lastPathComponent) uses \(token): ask FramePolicy through PacedTimeline instead")
            }
        }
    }

    @Test func theOnlyPlainTimelineIsThePacedOne() throws {
        for file in Self.sources() where file.lastPathComponent != "Energy.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("TimelineView("), "\(file.lastPathComponent) draws a TimelineView that the policy does not pace")
        }
    }

    @Test func theSensorIsOnlyStartedByTheSharedSource() throws {
        for file in Self.sources() where file.lastPathComponent != "TiltImp.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("startDeviceMotionUpdates") && !text.contains("startAccelerometerUpdates"),
                    "\(file.lastPathComponent) reads the motion sensor on its own")
        }
    }
}
