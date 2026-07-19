import SwiftUI

enum ArcTab: CaseIterable {
    case myFlights, friends, passport
    var title: String { switch self { case .myFlights: "My Flights"; case .friends: "Friends"; case .passport: "Passport" } }
    var icon: String { switch self { case .myFlights: "airplane"; case .friends: "person.2.fill"; case .passport: "book.pages.fill" } }
}

/// Flighty-style floating pill: 3 tabs in a capsule + a separate circular search button.
struct ArcTabBar: View {
    @Binding var selection: ArcTab
    var onSearch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(ArcTab.allCases, id: \.self) { tab in
                    Button { selection = tab } label: { item(tab) }
                        .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 54, height: 54)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
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
        .background(active ? ArcTheme.action.opacity(0.12) : .clear, in: Capsule())
    }
}
