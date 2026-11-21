import AVFoundation
import Foundation
import Testing
@testable import ImpKit

@Suite struct MediaFileTests {
    @Test func kindsFollowTheMIMEType() {
        #expect(MediaFile(data: Data([1]), mimeType: "image/png", name: "a").kind == .image)
        #expect(MediaFile(data: Data([1]), mimeType: "audio/wav", name: "a").kind == .audio)
        #expect(MediaFile(data: Data([1]), mimeType: "video/quicktime", name: "a").kind == .video)
        #expect(MediaFile(data: Data([1]), mimeType: "application/pdf", name: "a").kind == .file)
        #expect(MediaFile.mimeType(forExtension: "MP3") == "audio/mpeg")
        #expect(MediaFile.mimeType(forExtension: "mov") == "video/quicktime")
        #expect(MediaFile.mimeType(forExtension: "jpeg") == "image/jpeg")
        #expect(MediaFile.mimeType(forExtension: "zzzzqq") == "application/octet-stream")
    }

    @Test func dataURLCarriesTheBytes() {
        let file = MediaFile(data: Data([1, 2, 3]), mimeType: "audio/wav", name: "s.wav")
        #expect(file.dataURL == "data:audio/wav;base64,AQID")
        let message = ChatMessage.user("hi", media: [file])
        #expect(message.images == [file.dataURL])
        #expect(ChatMessage.user("hi", media: []).images == nil)
    }

    @Test func limitsMatchTheCore() {
        #expect(MediaFile.maxBytes == 25 << 20)
        #expect(MediaFile.maxCount == 4)
        #expect(MediaFile.check(bytes: 0) == .empty)
        #expect(MediaFile.check(bytes: 1) == nil)
        #expect(MediaFile.check(bytes: 25 << 20) == nil)
        #expect(MediaFile.check(bytes: (25 << 20) + 1) == .tooBig)
        #expect(MediaFile.canAdd(to: 3))
        #expect(!MediaFile.canAdd(to: 4))
    }

    @Test func emptyWordsGetALineForWhatIsAttached() {
        func file(_ mime: String) -> MediaFile { MediaFile(data: Data([1]), mimeType: mime, name: "x") }
        #expect(MediaFile.defaultWords(for: [file("image/png"), file("image/jpeg")]) == "Take a look at this photo.")
        #expect(MediaFile.defaultWords(for: [file("audio/wav")]) == "Listen to this.")
        #expect(MediaFile.defaultWords(for: [file("video/mp4")]) == "Watch this.")
        #expect(MediaFile.defaultWords(for: [file("audio/wav"), file("video/mp4")]) == "Take a look at this.")
        let turn = Briefing.message("  ", media: [file("audio/wav")], paths: ["/w/attachments/x.wav"])
        #expect(turn.content?.hasPrefix("Listen to this.") == true)
        #expect(turn.content?.contains("saved at /w/attachments/x.wav") == true)
        #expect(turn.images?.count == 1)
        #expect(Briefing.remembered(turn).images == nil)
    }

    @Test func wavHeaderRoundTrips() {
        let header = WavHeader.make(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 32_000)
        #expect(header.count == 44)
        let data = header + Data(count: 32_000)
        #expect(WavHeader.parse(data) == WavHeader.Info(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 32_000))
        #expect(WavHeader.parse(Data("not a wav file at all".utf8)) == nil)
    }

    @Test func recorderSettingsWriteSixteenKilohertzMonoWav() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imp-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: SoundRecorder.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)!
            buffer.frameLength = 1600
            try file.write(from: buffer)
        }
        let info = try #require(WavHeader.parse(try Data(contentsOf: url)))
        #expect(info.sampleRate == 16_000 && info.channels == 1 && info.bitsPerSample == 16)
        #expect(info.dataBytes == 3_200)
    }

    @Test func namesAreSafeAndUnique() throws {
        let file = MediaFile(data: Data([1]), mimeType: "video/quicktime", name: "../../My holiday clip!.MOV")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = file.fileName(at: date)
        #expect(name == "My-holiday-clip-1700000000000.mov")
        #expect(!name.contains("/"))
        #expect(file.fileName(at: date) { $0 == name } == "My-holiday-clip-1700000000000-2.mov")
        #expect(MediaFile(data: Data([1]), mimeType: "audio/wav", name: "").fileName(at: date) == "sound-1700000000000.wav")
        #expect(MediaFile(data: Data([1]), mimeType: "image/jpeg", name: "日本語.jpeg").fileName(at: date) == "picture-1700000000000.jpg")
    }

    @Test func workspaceSavesAnyMediaInAttachments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-ws-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = MediaFile(data: Data([9, 9]), mimeType: "audio/wav", name: "sound.wav")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try Workspace.save(file, in: dir, at: date)
        let b = try Workspace.save(file, in: dir, at: date)
        #expect(a != b)
        #expect(a.deletingLastPathComponent().lastPathComponent == "attachments")
        #expect(try Data(contentsOf: a) == Data([9, 9]))
    }

    @Test func askWithAttachmentsKeepsTheWireShape() throws {
        let imp = UUID(), one = UUID()
        let plain = LinkMessage.ask(imp: imp, text: "hi")
        let json = LinkMessage.wire(String(decoding: try JSONEncoder.link.encode(plain), as: UTF8.self))
        #expect(!json.contains("attachments"))
        let back = try JSONDecoder.link.decode(LinkMessage.self, from: Data(LinkMessage.parse(json).utf8))
        #expect(back == plain)
        let with = LinkMessage.ask(imp: imp, text: "hi", attachments: [one])
        let wire = LinkMessage.wire(String(decoding: try JSONEncoder.link.encode(with), as: UTF8.self))
        #expect(wire.contains(one.uuidString))
        #expect(try JSONDecoder.link.decode(LinkMessage.self, from: Data(LinkMessage.parse(wire).utf8)) == with)
    }
}
