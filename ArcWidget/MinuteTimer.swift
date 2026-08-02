import SwiftUI

extension Text {
    /// Self-updating countdown at MINUTE precision — "2h 40m", never
    /// "2:40:12". Flight times aren't second-accurate, and a ticking seconds
    /// column promises an exactness the data doesn't have. Still fully
    /// system-animated: iOS re-renders it each minute with the app dead and
    /// the device offline. Phase flips at the target date (staleDate
    /// re-renders) retire it before it could count negative.
    ///
    /// DYNAMIC ISLAND ONLY: the lock-screen Live Activity renderer draws
    /// TimeDataSource text as placeholder dashes ("–h ––m") — verified on
    /// simulator. Lock screen and widget timelines use `style: .relative`
    /// instead, which is also minute-precision.
    static func minuteCountdown(to date: Date) -> Text {
        // dateRange, not durationOffset: the offset counts now − date, which
        // renders future targets with a minus sign ("-2h 40m").
        Text(.dateRange(endingAt: date),
             format: Date.ComponentsFormatStyle(style: .narrow, fields: [.hour, .minute]))
    }
}
