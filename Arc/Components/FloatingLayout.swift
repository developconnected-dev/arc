import SwiftUI

/// The vertical slice of the screen, as fractions from the top, that map
/// content is framed into; everything outside it is covered by chrome.
struct MapBand: Equatable {
    var top: Double
    var bottom: Double
    /// What every surface assumed before My Trips floated: a sheet over the lower half.
    static let upperHalf = MapBand(top: 0, bottom: 0.5)
}

/// Where everything on the floating My Trips surface sits, from the screen
/// and its insets alone. Pure, so the no-overlap rules are tested rather than
/// eyeballed (docs/superpowers/specs/2026-09-15-floating-trips-design.md).
struct MyTripsLayout: Equatable {
    static let margin: CGFloat = 16
    static let panelMargin: CGFloat = 12
    static let gap: CGFloat = 8
    static let control: CGFloat = 44
    /// The "Add a trip" accessory above the tab bar, measured on the simulator
    /// (bottom inset 139 with it, 83 without).
    static let accessoryHeight: CGFloat = 56
    static let panelOpeningFraction: CGFloat = 0.58
    /// The panel's drag strip as laid out: `BottomSheet`'s 50 pt zone less the
    /// 12 pt the content overlaps, so the detail's menu and X line up as before.
    static let panelStrip: CGFloat = 38

    /// The whole screen, safe areas included.
    let size: CGSize
    let safeTop: CGFloat
    /// How far the tab bar reaches up from the bottom edge, without the accessory.
    let tabBarClearance: CGFloat
    /// iOS 26.1 can switch the accessory off while a detail is open; 26.0 cannot.
    var accessoryHidesForDetail: Bool = true
    /// Whether the accessory is on screen under the cards. With no trips,
    /// iOS 26.1 hides it, and the list sits on the tab bar instead.
    var listClearsAccessory: Bool = true

    // MARK: Top row

    var topBarY: CGFloat { safeTop + 4 }
    var topBarBottom: CGFloat { topBarY + Self.control }

    // MARK: Cards

    /// So the list area is never negative.
    var listBottom: CGFloat {
        max(unfoldedListTop, size.height - tabBarClearance - (listClearsAccessory ? Self.accessoryHeight : 0) - Self.gap)
    }
    /// Below the top row and the Show Less / recenter row.
    var unfoldedListTop: CGFloat { topBarBottom + Self.gap + Self.control + Self.gap }

    /// Both states sit on `listBottom`. Folded, the stack is as tall as the
    /// invites plus the current journey's card (`foldedHeight`); unfolded, as
    /// tall as every card (`contentHeight`), never shorter than the folded
    /// stack and never above `unfoldedListTop`, where a taller list stops and
    /// scrolls.
    func listTop(folded: Bool, foldedHeight: CGFloat, contentHeight: CGFloat) -> CGFloat {
        let height = folded ? foldedHeight : max(foldedHeight, contentHeight)
        return max(unfoldedListTop, listBottom - height)
    }

    /// Room above short content in the fixed-frame list, so an unfolded
    /// stack sits on the bottom edge like the folded one.
    func contentTopSpacer(contentHeight: CGFloat) -> CGFloat {
        max(0, (listBottom - unfoldedListTop) - contentHeight)
    }

    func pillRowY(listTop: CGFloat) -> CGFloat { listTop - Self.gap - Self.control }

    // MARK: Detail panel

    var panelBottom: CGFloat {
        size.height - tabBarClearance - (accessoryHidesForDetail ? 0 : Self.accessoryHeight) - Self.gap
    }
    var panelHighestTop: CGFloat { topBarBottom + Self.gap }

    /// 58 % of the screen, unless that would hide part of the header: the header rule wins.
    func panelOpeningTop(headerHeight: CGFloat) -> CGFloat {
        clampPanelTop(size.height * (1 - Self.panelOpeningFraction), headerHeight: headerHeight)
    }

    /// As low as the panel goes: its strip and the whole header still showing.
    func panelLowestTop(headerHeight: CGFloat) -> CGFloat {
        max(panelHighestTop, panelBottom - Self.panelStrip - Morph.detailTopInset - headerHeight)
    }

    func clampPanelTop(_ top: CGFloat, headerHeight: CGFloat) -> CGFloat {
        min(max(top, panelHighestTop), panelLowestTop(headerHeight: headerHeight))
    }

    /// Terminal map / My plane need the map: a panel taller than the
    /// opening height comes down to it; a lower one stays where it is.
    /// Always within the current header's clamp, never above it.
    func panelTopForGroundView(current: CGFloat, headerHeight: CGFloat) -> CGFloat {
        clampPanelTop(max(current, panelOpeningTop(headerHeight: headerHeight)), headerHeight: headerHeight)
    }

    /// The recenter circle's top edge above the panel, or nil where it would
    /// crowd the top row.
    func recenterYAbovePanel(panelTop: CGFloat) -> CGFloat? {
        let y = panelTop - Self.gap - Self.control
        return y >= topBarBottom + Self.gap ? y : nil
    }

    /// The map between the top row and whatever covers the screen from `coverTop` down.
    /// A degenerate (zero-height) screen has no fractions to give, so it
    /// falls back to the framing every other surface already assumes.
    func band(coverTop: CGFloat) -> MapBand {
        guard size.height > 0 else { return .upperHalf }
        return MapBand(top: Double(topBarBottom / size.height),
                       bottom: Double(max(coverTop, topBarBottom + 1) / size.height))
    }
}

/// The top row's centre pill ("My Trips", or a live readout) never touches
/// the avatar or the share/"..." capsule.
enum TopPillPlacement {
    /// Centred on the screen when that keeps `gap` to both neighbours;
    /// otherwise slid toward the roomier side until it does; if the pill is
    /// wider than the room itself, centred in the room — shrinking the text
    /// to fit, if any, is the caller's job, not this function's.
    static func centreX(pillWidth: CGFloat, width: CGFloat,
                        leadingEdge: CGFloat, trailingEdge: CGFloat,
                        gap: CGFloat = MyTripsLayout.gap) -> CGFloat {
        let lowest = leadingEdge + gap + pillWidth / 2
        let highest = trailingEdge - gap - pillWidth / 2
        guard lowest <= highest else { return (leadingEdge + trailingEdge) / 2 }
        return min(max(width / 2, lowest), highest)
    }

    static func maxWidth(leadingEdge: CGFloat, trailingEdge: CGFloat,
                         gap: CGFloat = MyTripsLayout.gap) -> CGFloat {
        max(0, trailingEdge - leadingEdge - 2 * gap)
    }
}

/// Speed and altitude for the flight a detail is showing, in the units the
/// app has always used, grouped the same way for both numbers, each part
/// dropped on its own if it isn't a sane finite reading (and, for speed,
/// not negative), and shown only while the position is fresh — neither
/// stale nor from more than a minute in the future.
enum LiveReadout {
    static let freshness: TimeInterval = 15 * 60
    /// Clock skew can put a reading a little ahead of `now`; anything
    /// further out than this is not a real position, so it counts as stale.
    static let futureTolerance: TimeInterval = 60

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = "'"
        f.maximumFractionDigits = 0
        return f
    }()

    static func text(speed: Double?, altitude: Double?, updatedAt: Date?, now: Date = .now) -> String? {
        guard let updatedAt else { return nil }
        let age = now.timeIntervalSince(updatedAt)
        guard age < freshness, age >= -futureTolerance else { return nil }
        let speedPart = speed.flatMap { $0.isFinite && $0 >= 0 ? "\(groupedText($0 * 3.6)) km/h" : nil }
        let altitudePart = altitude.flatMap { $0.isFinite ? "\(groupedText($0)) m" : nil }
        let parts = [speedPart, altitudePart].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func groupedText(_ value: Double) -> String {
        let rounded = value.rounded()
        return formatter.string(from: NSNumber(value: rounded)) ?? "\(Int(rounded))"
    }
}
