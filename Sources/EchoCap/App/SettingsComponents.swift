import SwiftUI

/// 参考图风格的分组：标题在卡片外，卡片内是若干行，卡片下可带灰色说明。
struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))

            VStack(spacing: 0) {
                content
            }
            .background(Color(nsColor: .quaternarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }
}

/// 一行：左标签、右控件。
struct SettingsRow<Control: View>: View {
    let label: String
    var showDivider: Bool = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .lineLimit(1)
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            if showDivider {
                VStack {
                    Spacer()
                    Divider().padding(.leading, 16)
                }
            }
        }
    }
}

/// 顶部居中的胶囊切换器。
struct CapsuleTabSwitcher: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                let selected = selection == tab
                Text(tab.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(
                            selected ? Color(nsColor: .controlBackgroundColor) : .clear
                        )
                    )
                    .contentShape(Capsule())
                    .onTapGesture { selection = tab }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
    }
}
