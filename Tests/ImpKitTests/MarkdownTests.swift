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

    @Test func severalPlayersInARowStayApartAndInOrder() {
        #expect(outline("![one](1.mp3#autoplay)![two](2.mp3#autoplay)\n![a](a.mp4)\n![b](b.mp4) ![p](p.png)![q](q.png)")
                == ["audio 1.mp3 one autoplay", "audio 2.mp3 two autoplay", "video a.mp4 a", "video b.mp4 b", "img p.png p", "img q.png q"])
    }

    @Test func picturesAndPlayersInListsQuotesHeadingsAndTablesStillShow() {
        #expect(outline("- first ![a](a.mp3#autoplay)\n- ![b](b.mp3#autoplay) second")
                == ["0 • first", "audio a.mp3 a autoplay", "0 • second", "audio b.mp3 b autoplay"])
        #expect(outline("- ![a](a.mp3)\n- ![b](b.mp3)") == ["audio a.mp3 a", "audio b.mp3 b"])
        #expect(outline("> wise ![q](q.png)") == ["> wise", "img q.png q"])
        #expect(outline("> ![q](q.mp4)") == ["video q.mp4 q"])
        #expect(outline("# Song ![s](s.m4a)") == ["h1 Song", "audio s.m4a s"])
        #expect(outline("| a | b |\n|--|--|\n| ![c](c.png) | ![d](d.mov) |\n\nafter")
                == ["table 2 [\"a\", \"b\"] [[\"c\", \"d\"]]", "img c.png c", "video d.mov d", "p after"])
    }

    @Test func aLinkedVideoStillPlays() {
        #expect(outline("[![v](v.mp4#autoplay)](https://x.com)") == ["video v.mp4 v autoplay"])
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
