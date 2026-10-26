import Foundation
import Testing
@testable import ImpKit

@Suite struct MarkdownTests {
    /// Each block as plain text, to compare what gets drawn.
    private func outline(_ text: String) -> [String] {
        Markdown.blocks(text).map { block in
            switch block {
            case .paragraph(let s): "p \(String(s.characters))"
            case .heading(let level, let s): "h\(level) \(String(s.characters))"
            case .listItem(let marker, let depth, let s): "\(depth) \(marker ?? "_") \(String(s.characters))"
            case .quote(let s): "> \(String(s.characters))"
            case .code(let s): "code \(s)"
            case .image(let url, let alt, let link): "img \(url.absoluteString) \(alt)" + (link.map { " → \($0.absoluteString)" } ?? "")
            case .table(let t): "table \(t.alignments.count) \(t.header.map { String($0.characters) }) \(t.rows.map { $0.map { String($0.characters) } })"
            case .rule: "rule"
            case .media(let url, let title, let kind, let autoplay): "\(kind) \(url.absoluteString) \(title)\(autoplay ? " autoplay" : "")"
            }
        }
    }

    @Test func keepsSingleNewlinesAndInlineStyling() {
        #expect(outline("**Hi** there\nsecond line") == ["p Hi there\nsecond line"])
        let bold = Markdown.blocks("**Hi**").first
        guard case .paragraph(let s)? = bold else { Issue.record("not a paragraph"); return }
        #expect(s.runs.first?.inlinePresentationIntent == .stronglyEmphasized)
    }

    @Test func listsNestAndNumber() {
        let md = "- one\n- two\n  1. inner\n  2. more\n\n1. first\n2. second"
        #expect(outline(md) == ["0 • one", "0 • two", "1 1. inner", "1 2. more", "0 1. first", "0 2. second"])
    }

    @Test func tablesKeepShapeAndAlignment() {
        let blocks = Markdown.blocks("| A | B | C |\n|:--|:-:|--:|\n| 1 | | 3 |\n| 4 | 5 | 6 |")
        guard case .table(let t)? = blocks.first, blocks.count == 1 else { Issue.record("not one table"); return }
        #expect(t.alignments == [.leading, .center, .trailing])
        #expect(t.header.map { String($0.characters) } == ["A", "B", "C"])
        #expect(t.rows.map { $0.map { String($0.characters) } } == [["1", "", "3"], ["4", "5", "6"]])
    }

    @Test func imagesStandApart() {
        #expect(outline("Look: ![a cat](https://x.com/cat.png) nice\n\n![rel](cat.png)")
                == ["p Look:", "img https://x.com/cat.png a cat", "p nice", "img cat.png rel"])
    }

    @Test func linkedImagesKeepThePictureAndTheLink() {
        #expect(outline("See [![a cat](https://x.com/cat.png?s=1&t=2)](https://x.com/page#top) [![b](b.png)](out/b.png)")
                == ["p See", "img https://x.com/cat.png?s=1&t=2 a cat → https://x.com/page#top", "img b.png b → out/b.png"])
        // Left alone inside code.
        #expect(outline("```\n[![a](b.png)](c)\n```") == ["code [![a](b.png)](c)"])
    }

    @Test func audioAndVideoEmbedLikePictures() {
        #expect(outline("Listen: ![My answer](reply.MP3#autoplay)\n\n![clip](https://x.com/a.mov) ![pic](a.png)")
                == ["p Listen:", "audio reply.MP3 My answer autoplay", "video https://x.com/a.mov clip", "img a.png pic"])
        #expect(outline("![v](/tmp/say%20it.m4a#t=3)") == ["audio /tmp/say%20it.m4a v"])   // other fragments: no autoplay
    }

    @Test func pathsBecomeFilesInTheImpsFolder() {
        let base = URL(fileURLWithPath: "/Users/me/Imp Folder", isDirectory: true)
        let resolve = { Markdown.resolve(URL(string: $0)!, base: base).absoluteString }
        #expect(resolve("picture-russian.png") == "file:///Users/me/Imp%20Folder/picture-russian.png")
        #expect(resolve("out/a.png") == "file:///Users/me/Imp%20Folder/out/a.png")
        #expect(resolve("/tmp/a%20b.png") == "file:///tmp/a%20b.png")
        #expect(resolve("~/Desktop/x.png") == URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/x.png").absoluteString)
        #expect(resolve("https://apple.com/x") == "https://apple.com/x")
        #expect(resolve("file:///tmp/x.png") == "file:///tmp/x.png")
    }

    @Test func otherBlocks() {
        #expect(outline("# Title\n\n> wise\n\n```swift\nlet x = 1\n```\n\n---") == ["h1 Title", "> wise", "code let x = 1", "rule"])
    }
}
