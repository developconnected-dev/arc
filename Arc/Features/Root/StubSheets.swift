import SwiftUI
import SwiftData

struct FriendsSheet: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Friends").font(ArcTheme.screenTitle)
            Text("Social is deferred — coming after core screens.")
                .font(ArcTheme.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, ArcTheme.screenPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

