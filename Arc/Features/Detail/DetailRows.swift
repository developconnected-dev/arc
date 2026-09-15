import SwiftUI

/// The one row style used below the header: an icon, a line of text, and
/// either a trailing value or a chevron. Rows sit in a `DetailGroup`, which
/// draws the hairlines between them.
struct DetailRow<Trailing: View>: View {
    let icon: String
    let text: String
    var subtitle: String? = nil
    var chevron: Bool = false
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(icon: String, text: String, subtitle: String? = nil, chevron: Bool = false,
         action: (() -> Void)? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = icon; self.text = text; self.subtitle = subtitle
        self.chevron = chevron; self.action = action; self.trailing = trailing
    }

    var body: some View {
        let content = HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.subheadline).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

extension DetailRow where Trailing == EmptyView {
    init(icon: String, text: String, subtitle: String? = nil, chevron: Bool = false,
         action: (() -> Void)? = nil) {
        self.init(icon: icon, text: text, subtitle: subtitle, chevron: chevron,
                  action: action) { EmptyView() }
    }
}

extension DetailRow where Trailing == Text {
    /// A row whose trailing side is a value in grey — or in a colour when
    /// the value is the news ("Risky").
    init(icon: String, text: String, subtitle: String? = nil, value: String,
         valueColor: Color = Color(.secondaryLabel), chevron: Bool = false,
         action: (() -> Void)? = nil) {
        self.init(icon: icon, text: text, subtitle: subtitle, chevron: chevron, action: action) {
            Text(value).font(.subheadline).foregroundStyle(valueColor)
        }
    }
}

/// One card holding rows, with a hairline between each pair. The rows are
/// handed in as a variadic view so callers can use `if`s freely.
struct DetailGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        _VariadicView.Tree(GroupLayout()) { content() }
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: ArcTheme.detailBoxCorner))
    }

    private struct GroupLayout: _VariadicView_MultiViewRoot {
        @ViewBuilder func body(children: _VariadicView.Children) -> some View {
            VStack(spacing: 0) {
                ForEach(children) { child in
                    if child.id != children.first?.id {
                        Divider().padding(.leading, 50)
                    }
                    child
                }
            }
        }
    }
}
