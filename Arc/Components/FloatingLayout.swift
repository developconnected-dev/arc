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
    /// The "Add a trip" accessory above the tab bar, measured on device (Task 9).
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

    // MARK: Top row

    var topBarY: CGFloat { safeTop + 4 }
    var topBarBottom: CGFloat { topBarY + Self.control }

    // MARK: Cards

    var listBottom: CGFloat { size.height - tabBarClearance - Self.accessoryHeight - Self.gap }
    /// Below the top row and the Show Less / recenter row.
    var unfoldedListTop: CGFloat { topBarBottom + Self.gap + Self.control + Self.gap }

    func listTop(folded: Bool, foldedHeight: CGFloat) -> CGFloat {
        folded ? max(unfoldedListTop, listBottom - foldedHeight) : unfoldedListTop
    }

    func pillRowY(listTop: CGFloat) -> CGFloat { listTop - Self.gap - Self.control }

    // MARK: Detail panel

    var panelBottom: CGFloat {
        size.height - tabBarClearance - (accessoryHidesForDetail ? 0 : Self.accessoryHeight) - Self.gap
    }
    var panelHighestTop: CGFloat { topBarBottom + Self.gap }
    var panelOpeningTop: CGFloat { max(panelHighestTop, size.height * (1 - Self.panelOpeningFraction)) }

    /// As low as the panel goes: its strip and the whole header still showing.
    func panelLowestTop(headerHeight: CGFloat) -> CGFloat {
        max(panelHighestTop, panelBottom - Self.panelStrip - Morph.detailTopInset - headerHeight)
    }

    func clampPanelTop(_ top: CGFloat, headerHeight: CGFloat) -> CGFloat {
        min(max(top, panelHighestTop), panelLowestTop(headerHeight: headerHeight))
    }

    /// Terminal map / My plane need the map: a panel taller than the
    /// opening height comes down to it; a lower one stays where it is.
    func panelTopForGroundView(current: CGFloat) -> CGFloat { max(current, panelOpeningTop) }

    /// The recenter circle's top edge above the panel, or nil where it would
    /// crowd the top row.
    func recenterYAbovePanel(panelTop: CGFloat) -> CGFloat? {
        let y = panelTop - Self.gap - Self.control
        return y >= topBarBottom + Self.gap ? y : nil
    }

    /// The map between the top row and whatever covers the screen from `coverTop` down.
    func band(coverTop: CGFloat) -> MapBand {
        MapBand(top: Double(topBarBottom / size.height),
                bottom: Double(max(coverTop, topBarBottom + 1) / size.height))
    }
}

/// The top row's centre pill ("My Trips", or a live readout) never touches
/// the avatar or the share/"..." capsule.
enum TopPillPlacement {
    /// Centred on the screen when that keeps `gap` to both neighbours;
    /// otherwise slid toward the roomier side until it does; if the pill is
    /// wider than the room itself, centred in the room (its text then shrinks).
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
/// app has always used, and only while the position is fresh.
enum LiveReadout {
    static let freshness: TimeInterval = 15 * 60

    static func text(speed: Double?, altitude: Double?, updatedAt: Date?, now: Date = .now) -> String? {
        guard let updatedAt, now.timeIntervalSince(updatedAt) < freshness else { return nil }
        let parts = [speed.map { "\(Int($0 * 3.6)) km/h" }, altitude.map(altitudeText)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func altitudeText(_ meters: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = "'"
        f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: meters)) ?? "\(Int(meters))") + " m"
    }
}
