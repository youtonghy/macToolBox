import SwiftUI

enum SettingsChrome {
    static let sidebarWidth: CGFloat = 196
    static let contentSpacing: CGFloat = 14
    static let sectionSpacing: CGFloat = 12
    static let sectionInnerSpacing: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 18
    static let innerCornerRadius: CGFloat = 12

    static let sectionBackground = Color.primary.opacity(0.055)
    static let sectionBorder = Color.white.opacity(0.14)
    static let cardBackground = Color.primary.opacity(0.055)
    static let cardBorder = Color.white.opacity(0.12)
}

struct SettingsSection<Content: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionInnerSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))

                    Spacer(minLength: 8)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                content
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsChrome.cornerRadius, style: .continuous)

        content
            .padding(SettingsChrome.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(SettingsChrome.sectionBackground))
            .overlay(shape.strokeBorder(SettingsChrome.sectionBorder, lineWidth: 1))
            .clipShape(shape)
    }
}

struct SettingsInnerCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)

        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(SettingsChrome.cardBackground))
            .overlay(shape.strokeBorder(SettingsChrome.cardBorder, lineWidth: 1))
            .clipShape(shape)
    }
}

struct SettingsFeatureRow: View {
    let symbolName: String
    let accent: Color
    let title: String
    var description: String = ""

    var body: some View {
        SettingsInnerCard {
            HStack(spacing: 12) {
                SettingsIconBadge(systemName: symbolName, accent: accent, emphasized: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }
}

struct SettingsValueRow: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        SettingsInnerCard {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text(value)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(accent.opacity(0.12))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(accent.opacity(0.22), lineWidth: 1)
                    )
            }
        }
    }
}

struct SettingsEmptyState: View {
    let symbolName: String
    let title: String
    var description: String = ""

    var body: some View {
        SettingsInnerCard {
            HStack(spacing: 12) {
                SettingsIconBadge(
                    systemName: symbolName,
                    accent: Color.secondary,
                    emphasized: false
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }
}

struct SettingsIconBadge: View {
    let systemName: String
    let accent: Color
    let emphasized: Bool

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(emphasized ? accent : accent.opacity(0.9))
            .frame(width: 28, height: 28)
            .background(
                Circle()
                    .fill(accent.opacity(emphasized ? 0.14 : 0.10))
            )
            .overlay(
                Circle()
                    .strokeBorder(accent.opacity(emphasized ? 0.28 : 0.16), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}
