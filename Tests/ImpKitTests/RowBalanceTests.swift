import ImpKit
import Testing

@Suite struct RowBalanceTests {
    @Test func oneLineWhenEverythingFits() {
        #expect(RowBalance.lineLengths(count: 4, fit: 6) == [4])
        #expect(RowBalance.lineLengths(count: 2, fit: 3) == [2])
    }

    @Test func neverLeavesOneItemAlone() {
        #expect(RowBalance.lineLengths(count: 10, fit: 9) == [5, 5])
        #expect(RowBalance.lineLengths(count: 7, fit: 3) == [3, 2, 2])
        #expect(RowBalance.lineLengths(count: 7, fit: 4) == [4, 3])
    }

    @Test func linesDifferByAtMostOneAndKeepEveryItem() {
        for count in 1...30 {
            for fit in 1...12 {
                let lines = RowBalance.lineLengths(count: count, fit: fit)
                #expect(lines.reduce(0, +) == count)
                #expect(lines.allSatisfy { $0 <= fit })
                #expect((lines.max() ?? 0) - (lines.min() ?? 0) <= 1)
                #expect(lines.count == (count + fit - 1) / fit)
            }
        }
    }

    @Test func degenerateInput() {
        #expect(RowBalance.lineLengths(count: 0, fit: 3).isEmpty)
        #expect(RowBalance.lineLengths(count: 3, fit: 0) == [1, 1, 1])
    }
}
