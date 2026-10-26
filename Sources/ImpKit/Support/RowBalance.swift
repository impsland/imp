/// How a grid splits items into lines so every line can span the full width: as few lines as
/// fit, with lengths that differ by at most one, the longer lines first. Ten items that need two
/// lines go five and five (never nine and one); seven in three lines go 3, 2, 2.
public enum RowBalance {
    /// `count` items, at most `fit` to a line.
    public static func lineLengths(count: Int, fit: Int) -> [Int] {
        guard count > 0 else { return [] }
        let fit = max(fit, 1)
        let lines = (count + fit - 1) / fit
        let base = count / lines, extra = count % lines
        return (0..<lines).map { $0 < extra ? base + 1 : base }
    }
}
