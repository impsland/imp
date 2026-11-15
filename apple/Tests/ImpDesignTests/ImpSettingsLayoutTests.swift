import CoreGraphics
import Testing
@testable import ImpDesign

@Suite("Imp Settings layout")
struct ImpSettingsLayoutTests {
    @Test("The list reads Brain, Personality, Look, Tools, Triggers, Moves")
    func listOrder() {
        #expect(ImpSetting.listOrder == [.brain, .personality, .look, .tools, .triggers, .moves])
        #expect(Set(ImpSetting.listOrder) == Set(ImpSetting.allCases))
    }

    @Test("Each marker has its own place around the Imp")
    func places() {
        #expect(ImpSetting.brain.place == .above)
        #expect(ImpSetting.look.place == .left)
        #expect(ImpSetting.personality.place == .right)
        #expect(ImpSetting.tools.place == .lowerLeft)
        #expect(ImpSetting.triggers.place == .lowerRight)
        #expect(ImpSetting.moves.place == .below)
        #expect(Set(ImpSetting.allCases.map(\.place)).count == ImpSetting.allCases.count)
    }

    @Test("A wide window with normal text shows the markers")
    func wide() {
        #expect(ImpSettingsLayout.mode(width: 900, largeText: false, screenReader: false) == .markers)
    }

    @Test("Below the narrow width it is a list, at the width it is not")
    func narrow() {
        let edge = CGFloat(Behavior.narrowWindowPoints)
        #expect(ImpSettingsLayout.mode(width: edge - 1, largeText: false, screenReader: false) == .list)
        #expect(ImpSettingsLayout.mode(width: edge, largeText: false, screenReader: false) == .markers)
    }

    @Test("Accessibility text sizes or a screen reader always give the list")
    func assistive() {
        #expect(ImpSettingsLayout.mode(width: 900, largeText: true, screenReader: false) == .list)
        #expect(ImpSettingsLayout.mode(width: 900, largeText: false, screenReader: true) == .list)
    }

    @Test("A panel sits beside the markers only when the window has room")
    func panelPlacement() {
        #expect(ImpSettingsLayout.panelBesideImp(width: ImpSettingsLayout.sidePanelMinWidth))
        #expect(!ImpSettingsLayout.panelBesideImp(width: ImpSettingsLayout.sidePanelMinWidth - 1))
        // Beside the panel, the stage still has room for the markers and the smallest Imp.
        let stage = ImpSettingsLayout.sidePanelMinWidth - Sizing.panelWidth
        #expect(stage == ImpSettingsGeometry.minStageWidth)
        #expect(stage >= 2 * ImpSettingsGeometry.markerWidth + ImpSettingsGeometry.minImp)
        // The side panel and a closed medium window agree: 780 fits a panel, 560 does not.
        #expect(ImpSettingsLayout.panelBesideImp(width: 780))
        #expect(!ImpSettingsLayout.panelBesideImp(width: 560))
    }

    private func arrangement(_ width: CGFloat, open: Bool, largeText: Bool = false, screenReader: Bool = false) -> ImpSettingsLayout.Arrangement {
        ImpSettingsLayout.arrangement(width: width, largeText: largeText, screenReader: screenReader, panelOpen: open)
    }

    @Test("Closed, the stage fills the window at every width")
    func closed() {
        for width: CGFloat in [360, 560, 780, 1100] {
            let a = arrangement(width, open: false)
            #expect(a == .stage)
            #expect(ImpSettingsLayout.stageWidth(total: width, arrangement: a) == width)
            #expect(ImpSettingsLayout.panelWidth(total: width, arrangement: a) == 0)
        }
    }

    @Test("Open, the stage and the panel share the window exactly when it is wide, else the panel takes over")
    func open() {
        for width: CGFloat in [780, 1100] {
            let a = arrangement(width, open: true)
            #expect(a == .besidePanel)
            let stage = ImpSettingsLayout.stageWidth(total: width, arrangement: a)
            let panel = ImpSettingsLayout.panelWidth(total: width, arrangement: a)
            #expect(panel == Sizing.panelWidth)
            #expect(stage + panel == width)
            #expect(stage >= ImpSettingsGeometry.minStageWidth)
        }
        for width: CGFloat in [360, 560] {
            let a = arrangement(width, open: true)
            #expect(a == .panelOnly)
            #expect(ImpSettingsLayout.panelWidth(total: width, arrangement: a) == width)
        }
        // The list never sits beside a panel, however wide the window.
        #expect(arrangement(1100, open: true, largeText: true) == .panelOnly)
        #expect(arrangement(1100, open: true, screenReader: true) == .panelOnly)
    }

    @Test("Closing and opening change only the arrangement: the widths add up to the window in both")
    func widthsAddUp() {
        for width: CGFloat in [560, 780, 1100] {
            for open in [false, true] {
                let a = arrangement(width, open: open)
                let stage = ImpSettingsLayout.stageWidth(total: width, arrangement: a)
                let panel = ImpSettingsLayout.panelWidth(total: width, arrangement: a)
                #expect(a == .besidePanel ? stage + panel == width : max(stage, panel) == width)
            }
        }
    }

    @Test("Geometry comes from the size tokens")
    func tokens() {
        #expect(ImpSettingsGeometry.markerWidth >= Sizing.marker)
        #expect(ImpSettingsGeometry.markerHeight > Sizing.marker)
        #expect(ImpSettingsGeometry.minImp < ImpSettingsGeometry.maxImp)
    }

    @Test("Markers stay inside the stage and do not touch each other or the Imp at 560, 780 and 1100")
    func markersFit() {
        let bar: CGFloat = 32
        for total: CGFloat in [560, 780, 1100] {
            for open in [false, true] {
                let a = arrangement(total, open: open)
                let width = ImpSettingsLayout.stageWidth(total: total, arrangement: a)
                for height: CGFloat in [520, 640, 900] {
                    let size = CGSize(width: width, height: height - bar)
                    let imp = ImpSettingsGeometry.imp(in: size)
                    #expect(imp >= ImpSettingsGeometry.minImp && imp <= ImpSettingsGeometry.maxImp)
                    let middle = CGRect(x: -imp / 2, y: -imp / 2, width: imp, height: imp)
                    var frames: [CGRect] = []
                    for setting in ImpSetting.allCases {
                        let o = ImpSettingsGeometry.offset(setting.place, imp: imp)
                        let frame = CGRect(x: o.width - ImpSettingsGeometry.markerWidth / 2, y: o.height - ImpSettingsGeometry.markerHeight / 2,
                                           width: ImpSettingsGeometry.markerWidth, height: ImpSettingsGeometry.markerHeight)
                        #expect(frame.minX >= -size.width / 2 && frame.maxX <= size.width / 2)
                        #expect(frame.minY >= -size.height / 2 && frame.maxY <= size.height / 2)
                        #expect(!frame.intersects(middle))
                        #expect(frames.allSatisfy { !$0.intersects(frame) })
                        frames.append(frame)
                    }
                }
            }
        }
    }

    @Test("The preview grows with the size setting and stays inside its frame")
    func previewScale() {
        #expect(ImpSettingsGeometry.previewScale(0.75) < ImpSettingsGeometry.previewScale(1.0))
        #expect(ImpSettingsGeometry.previewScale(1.0) < ImpSettingsGeometry.previewScale(1.7))
        #expect(ImpSettingsGeometry.previewScale(1.7) == 1)
        #expect(ImpSettingsGeometry.previewScale(5) == 1)
        #expect(ImpSettingsGeometry.previewScale(0) == ImpSettingsGeometry.previewScale(0.75))
    }
}

@Suite("Imp Settings navigation")
struct ImpSettingsNavigationTests {
    @Test("Back from the stage leaves, from a panel it closes the panel only")
    func backLevels() {
        var nav = ImpSettingsNavigation()
        #expect(nav.backLeaves)
        #expect(nav.back() == .leave)
        nav.open(.look)
        #expect(!nav.backLeaves)
        #expect(nav.back() == .closedPanel(focus: .look))
        #expect(nav.panel == nil)
        #expect(nav.back() == .leave)
    }

    @Test("A marker toggles its panel and switching keeps one level")
    func toggling() {
        var nav = ImpSettingsNavigation()
        nav.toggle(.tools)
        #expect(nav.panel == .tools)
        nav.toggle(.moves)
        #expect(nav.panel == .moves)
        #expect(nav.back() == .closedPanel(focus: .moves))
        nav.toggle(.brain)
        nav.toggle(.brain)
        #expect(nav.panel == nil)
    }

    @Test("A page opened by a link starts in its panel and returns to its marker")
    func opensAtPanel() {
        var nav = ImpSettingsNavigation(panel: .triggers)
        #expect(nav.back() == .closedPanel(focus: .triggers))
        #expect(nav.returnFocus == .triggers)
    }

    @Test("An open panel always has a place, beside the stage or instead of it")
    func openPanelHasAPlace() {
        for width in [300.0, 520, 700, 1100] as [CGFloat] {
            for large in [false, true] {
                let a = ImpSettingsLayout.arrangement(width: width, largeText: large, screenReader: false, panelOpen: true)
                #expect(a != .stage)
            }
        }
    }
}
