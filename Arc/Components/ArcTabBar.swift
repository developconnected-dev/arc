import SwiftUI

enum ArcTab: CaseIterable {
    case myFlights, friends, passport
    var title: String { switch self { case .myFlights: "My Flights"; case .friends: "Friends"; case .passport: "Passport" } }
    var icon: String { switch self { case .myFlights: "airplane"; case .friends: "person.2.fill"; case .passport: "book.pages.fill" } }
}

/// Floating pill: 3 tabs in a capsule + a separate circular search button.
///
/// Real Liquid Glass (`glassEffect`), not `.regularMaterial` — that's the
/// pre-iOS-26 blur, which is why this never looked like the system's own
/// chrome. A `GlassEffectContainer` groups the capsule and the search button so
/// they refract as one piece of glass rather than two unrelated panes, and
/// `.interactive()` gives them the press response system controls have.
struct ArcTabBar: View {
    @Binding var selection: ArcTab
    var onSearch: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(ArcTab.allCases, id: \.self) { tab in
                        Button { selection = tab } label: { item(tab) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 54, height: 54)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
            }
        }
        .padding(.horizontal, 16)
    }

    private func item(_ tab: ArcTab) -> some View {
        let active = selection == tab
        return VStack(spacing: 2) {
            Image(systemName: tab.icon).font(.system(size: 18, weight: .semibold))
            Text(tab.title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(active ? ArcTheme.action : Color(.secondaryLabel))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        // The selection marker stays a tint, not glass — glass on glass smears.
        .background(active ? ArcTheme.action.opacity(0.12) : .clear, in: Capsule())
    }
}
