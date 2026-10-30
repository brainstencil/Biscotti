import CoreGraphics
import Foundation

/// Finds the topmost visible item from the frames of the rows the list has
/// materialized, in the scroll view's coordinate space. In the app the
/// scroll view runs under the toolbar, so what the reader sees starts at
/// the top content inset, not at y = 0.
///
/// The `List` spike showed that `onAppear`/`onDisappear` overscan by one or
/// two rows above the visible area, so appearance cannot tell which row is
/// at the top; per-row geometry can. Not observable: frames change on every
/// scroll frame and must not re-render anything.
final class VisibleRowTracker {
    private struct Row {
        var startTime: TimeInterval
        var frame: CGRect
    }

    private var rows: [String: Row] = [:]
    /// The content position at the top of what the reader sees, below the
    /// top content inset.
    private var visibleTop: CGFloat = 0
    /// The top content inset (under the toolbar), in the scroll view's space.
    private var insetTop: CGFloat = 0
    /// The header row's height. It is the list's first row, so it covers
    /// content offsets `0 ..< headerHeight`.
    private var headerHeight: CGFloat = .infinity
    /// The scroll view's height, in its own space: rows below it, less the
    /// bottom inset, are out of view.
    private var viewportHeight: CGFloat = .infinity
    /// The bottom content inset (under the meeting page's band and chat card).
    private var insetBottom: CGFloat = 0

    func update(id: String, startTime: TimeInterval, frame: CGRect) {
        rows[id] = Row(startTime: startTime, frame: frame)
    }

    func remove(id: String) {
        rows[id] = nil
    }

    func updateHeader(height: CGFloat) {
        headerHeight = height
    }

    /// Header visibility follows the scroll position, which is reported on
    /// every jump (Page Down, End, a programmatic scroll), unlike the
    /// header row's own geometry, which stops when the row is recycled.
    func updateScroll(offsetY: CGFloat, insetTop: CGFloat, insetBottom: CGFloat = 0, viewportHeight: CGFloat = .infinity) {
        visibleTop = offsetY + insetTop
        self.insetTop = insetTop
        self.insetBottom = insetBottom
        self.viewportHeight = viewportHeight
    }

    /// The lower edge of what the reader sees, in the scroll view's space.
    private var visibleBottom: CGFloat {
        viewportHeight - insetBottom
    }

    /// Where an item's row is against what the reader sees, from the rows
    /// the list has made.
    func placement(of id: String) -> RowPlacement {
        guard let row = rows[id] else { return .notShown }
        if row.frame.maxY <= insetTop { return .above }
        if row.frame.minY >= visibleBottom { return .below }
        return .inView
    }

    /// The start times of the rows in view, earliest to latest; nil with none.
    var timesInView: ClosedRange<TimeInterval>? {
        let times = rows.values
            .filter { $0.frame.maxY > insetTop && $0.frame.minY < visibleBottom }
            .map(\.startTime)
        guard let first = times.min(), let last = times.max() else { return nil }
        return first ... last
    }

    /// What the reader sees, for the reveal's landing log.
    var visibleSpan: VisibleSpan {
        VisibleSpan(times: timesInView, height: viewportHeight, insetTop: insetTop, insetBottom: insetBottom)
    }

    var isHeaderVisible: Bool {
        visibleTop < headerHeight
    }

    /// The start time of the first row whose middle is below the top inset,
    /// or nil while the header is visible (the reader is at the top, and a
    /// swap should leave them there).
    var topVisibleStartTime: TimeInterval? {
        guard !isHeaderVisible else { return nil }
        return rows.values
            .filter { $0.frame.midY >= insetTop }
            .min { $0.frame.minY < $1.frame.minY }?
            .startTime
    }
}
