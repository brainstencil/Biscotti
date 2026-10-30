import Foundation

/// Where a row is against the part of the list the reader sees.
enum RowPlacement: Equatable {
    case inView
    case above
    case below
    /// The list has not made the row: it is far from what is in view.
    case notShown
}

/// What the reader sees, for the landing log: the start times of the rows in
/// view; the edges of the view in the list's space (the height, less the top
/// and bottom insets under a toolbar or a pinned band and card); and where
/// the list's frame sits in the window, which row frames are read against.
/// The landing log shows whether the list's frame is its scroll view's (at
/// the window's top on the meeting page, under the toolbar's inset).
struct VisibleSpan: Equatable, CustomStringConvertible {
    var times: ClosedRange<TimeInterval>?
    var height: CGFloat
    /// The list's top edge in the window; not finite before it is reported.
    var listTop: CGFloat
    var listHeight: CGFloat
    var insetTop: CGFloat
    var insetBottom: CGFloat

    var description: String {
        let rows = times.map { String(format: "%.1f–%.1f s", $0.lowerBound, $0.upperBound) } ?? "no rows"
        return "\(rows) (view \(Self.points(height)) pt, list at \(Self.points(listTop)) pt in the window, "
            + "\(Self.points(listHeight)) pt high, insets \(Self.points(insetTop)) top, \(Self.points(insetBottom)) bottom)"
    }

    /// Whole points; "unknown" before the list has reported its geometry.
    private static func points(_ value: CGFloat) -> String {
        value.isFinite ? String(Int(value.rounded())) : "unknown"
    }
}

/// Where a reveal's scroll landed. The list makes its rows lazily and
/// estimates the height of rows it has not made, so a scroll to an item
/// far from what is in view can land short of it or past it; asking again
/// once the rows around the landing are measured gets closer. This asks
/// for the item again, at most `attempts` times, while it is out of view.
struct RevealLandingCheck: Equatable {
    static let attempts = 3
    /// How long after a scroll to the item its landing is checked: enough
    /// for the rows around it to lay out and report their frames.
    static let delay: Duration = .milliseconds(200)

    enum Outcome: Equatable {
        /// The revealed item is in view.
        case landed
        /// Out of view: ask for the item again; this is attempt `n` of `attempts`.
        case retry(attempt: Int)
        /// Still out of view after the last attempt.
        case gaveUp
    }

    let itemID: String
    /// The revealed time, for the log.
    let time: TimeInterval
    private(set) var retries = 0

    mutating func landed(_ placement: RowPlacement) -> Outcome {
        if placement == .inView { return .landed }
        guard retries < Self.attempts else { return .gaveUp }
        retries += 1
        return .retry(attempt: retries)
    }
}
