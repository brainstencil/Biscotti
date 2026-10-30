import CoreGraphics
import Foundation

/// Finds the topmost visible item from the frames of the rows the list has
/// materialized. Rows and the list both report their frames in the window
/// (`.global`), and the tracker works in the scroll view's space: y = 0 at
/// the top of the list's scroll view, which runs under the toolbar, so what
/// the reader sees starts at the top content inset, not at y = 0. A macOS
/// `List` is not a SwiftUI `ScrollView`, so a row's `.scrollView` frame
/// resolves to an outer space; it matched only where the scroll view starts
/// at the window's top (the meeting page), and was off by the list's origin
/// in the recording drawer (meeting chat phase 10 hardware check F14).
///
/// Measured on macOS (meeting chat phase 10, hardware re-check 3): the
/// List's own frame excludes the content insets, the areas under the
/// toolbar and the pinned bottom. On the meeting page it was 52 pt down the
/// window and 206 pt high in a 1290 pt scroll view with insets of 52 and
/// 1032 pt. So the scroll view's top in the window is the list's top less
/// the top inset, and rows are read against that.
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
    /// The list's frame in the window (`.global`), which excludes the
    /// content insets; nil until the list has reported it.
    private var listFrame: CGRect?
    /// The content position at the top of what the reader sees, below the
    /// top content inset.
    private var visibleTop: CGFloat = 0
    /// The top content inset (under the toolbar), in the scroll view's space.
    private var insetTop: CGFloat = 0
    /// The header row's height. It is the list's first row, so it covers
    /// content offsets `0 ..< headerHeight`.
    private var headerHeight: CGFloat = .infinity
    /// The scroll view's height (`containerSize`), insets included: rows
    /// below it, less the bottom inset, are out of view.
    private var viewportHeight: CGFloat = .infinity
    /// The bottom content inset (under the meeting page's band and chat card),
    /// in the scroll view's space.
    private var insetBottom: CGFloat = 0

    /// A row's frame in the window (`.global`).
    func update(id: String, startTime: TimeInterval, frame: CGRect) {
        rows[id] = Row(startTime: startTime, frame: frame)
    }

    /// The list's frame in the window (`.global`): row frames are read
    /// against the scroll view's top, its top edge less the top inset.
    func updateList(frame: CGRect) {
        listFrame = frame
    }

    /// The scroll view's top in the window: the list's top less the top
    /// inset; 0 until the list has reported its frame.
    private var scrollViewTop: CGFloat {
        listFrame.map { $0.minY - insetTop } ?? 0
    }

    /// A row's frame in the scroll view's space: y = 0 at its top edge.
    private func inScrollViewSpace(_ frame: CGRect) -> CGRect {
        frame.offsetBy(dx: 0, dy: -scrollViewTop)
    }

    /// The rows, with their frames in the scroll view's space.
    private var listRows: [Row] {
        rows.values.map { Row(startTime: $0.startTime, frame: inScrollViewSpace($0.frame)) }
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
        let frame = inScrollViewSpace(row.frame)
        if frame.maxY <= insetTop { return .above }
        if frame.minY >= visibleBottom { return .below }
        return .inView
    }

    /// The start times of the rows in view, earliest to latest; nil with none.
    var timesInView: ClosedRange<TimeInterval>? {
        let times = listRows
            .filter { $0.frame.maxY > insetTop && $0.frame.minY < visibleBottom }
            .map(\.startTime)
        guard let first = times.min(), let last = times.max() else { return nil }
        return first ... last
    }

    /// What the reader sees, for the reveal's landing log.
    var visibleSpan: VisibleSpan {
        VisibleSpan(
            times: timesInView, height: viewportHeight,
            listTop: listFrame?.minY ?? .nan, listHeight: listFrame?.height ?? .nan,
            insetTop: insetTop, insetBottom: insetBottom
        )
    }

    var isHeaderVisible: Bool {
        visibleTop < headerHeight
    }

    /// The start time of the first row whose middle is below the top inset,
    /// or nil while the header is visible (the reader is at the top, and a
    /// swap should leave them there).
    var topVisibleStartTime: TimeInterval? {
        guard !isHeaderVisible else { return nil }
        return listRows
            .filter { $0.frame.midY >= insetTop }
            .min { $0.frame.minY < $1.frame.minY }?
            .startTime
    }
}
