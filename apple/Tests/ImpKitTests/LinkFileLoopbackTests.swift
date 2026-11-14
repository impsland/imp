import Foundation
import Testing
@testable import ImpKit

/// A picture a visiting Imp's reply shows comes over to the phone in parts, the way the Mac sends it
/// (`DeviceLink.sendFile`): each part waits for the socket to drain before the next.
@MainActor
@Suite(.serialized) struct LinkFileLoopbackTests {
    func node(_ name: String, kind: LinkKind) throws -> LinkNode {
        var options = LinkNode.Options()
        options.port = nil
        options.bonjour = false
        options.watchesNetwork = false
        options.hosts = ["127.0.0.1"]
        options.tick = 0.1
        return try LinkNode(name: name, kind: kind, storage: LinkMemoryStorage(), options: options)
    }

    @Test func aMegabytePictureArrivesWhole() async throws {
        let mac = try node("Studio", kind: .mac)
        let phone = try node("Pocket", kind: .phone)
        let onMac = Watcher(), onPhone = Watcher()
        onMac.attach(to: mac)
        onPhone.attach(to: phone)
        await mac.start()
        await phone.start()
        defer { mac.stop(); phone.stop() }
        _ = try await phone.join(try #require(mac.invite()))
        #expect(await onMac.wait { mac.isConnected(phone.device.id) && phone.isConnected(mac.device.id) })
        mac.setTrusted(phone.device.id, true)

        // The Mac's Imp goes to the phone.
        let imp = LinkImp(id: UUID(), name: "Dot", hue: 0.3, scale: 1, traits: .plain)
        let transfer = try #require(mac.pass(imp, entry: LinkEntry(side: .left, height: 0.5, speed: 600), to: phone.device.id))
        #expect(await onPhone.wait { onPhone.events.contains { if case .message(.pass, _) = $0 { true } else { false } } })
        #expect(phone.accept(transfer))
        #expect(await onMac.wait { mac.holder(of: imp.id) == phone.device.id })

        // The phone asks for a file; the Mac answers in 256 KB parts, as DeviceLink does.
        let request = UUID()
        #expect(phone.send(.file(id: request, imp: imp.id, ref: "imp-file://x/screenshot.png"), to: mac.device.id))
        #expect(await onMac.wait { onMac.events.contains { if case .message(.file(let id, _, _), _) = $0 { id == request } else { false } } })
        let size = 1_028_424
        let data = Data((0..<size).map { UInt8($0 % 251) })
        var offset = 0
        var sent = 0
        repeat {
            let chunk = data.subdata(in: offset..<min(offset + LinkFilePart.chunk, size))
            let part = LinkFilePart(name: "screenshot.png", size: size, offset: offset, data: chunk)
            let ok = await mac.sendAndWait(.filePart(id: request, part: part), to: phone.device.id)
            #expect(ok, "part at \(offset) was not sent")
            guard ok else { break }
            offset += chunk.count
            sent += 1
        } while offset < size
        let received = { onPhone.events.filter { if case .message(.filePart(let id, _), _) = $0 { id == request } else { false } }.count }
        #expect(await onPhone.wait { received() == sent })
        #expect(sent == 4 && received() == 4)
    }
}
