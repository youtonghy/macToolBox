import AppKit
import SwiftUI

/// Location picker whose selection switches the system location immediately.
/// Used by Settings → 网络位置; the menu-bar quick-controls row renders its
/// own flat location menu (a `Picker` inside `Menu` would nest a submenu).
struct NetworkLocationPicker: View {
    @ObservedObject var model: NetworkLocationModel

    var body: some View {
        Picker(
            L10n.string("当前位置"),
            selection: Binding(
                get: { model.snapshot.current },
                set: { if let name = $0 { model.switchTo(name) } }
            )
        ) {
            if model.snapshot.current == nil {
                Text(L10n.string("未知")).tag(String?.none)
            }
            ForEach(model.snapshot.locations, id: \.self) { name in
                Text(name).tag(Optional(name))
            }
        }
        .labelsHidden()
    }
}

// MARK: - Settings

struct NetworkLocationSettingsView: View {
    @ObservedObject var model: NetworkLocationModel
    @State private var newLocationName = ""
    @State private var ruleSSID = ""
    @State private var ruleLocation: String?
    @State private var ruleError: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                locationsSection
                autoSwitchSection
                if model.autoSwitch.isEnabled {
                    rulesSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
        .onAppear { model.refreshSSIDAuthorization() }
    }

    // MARK: Locations

    private var locationsSection: some View {
        SettingsSection(
            title: L10n.string("网络位置"),
            subtitle: L10n.string("等同于 networksetup -switchtolocation")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(L10n.string("当前位置"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    NetworkLocationPicker(model: model)
                        .frame(width: 220)
                        .disabled(model.snapshot.locations.isEmpty)
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(L10n.string("刷新位置列表"))
                    .accessibilityLabel(L10n.string("刷新位置列表"))
                }

                HStack(spacing: 10) {
                    TextField(L10n.string("新位置名称"), text: $newLocationName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(createLocation)
                    Button(L10n.string("新建位置"), action: createLocation)
                        .disabled(newLocationName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Text(L10n.string("新位置会包含默认网络服务。修改系统网络设置可能需要管理员授权。"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Auto switch

    private var autoSwitchSection: some View {
        SettingsSection(
            title: L10n.string("按 SSID 自动切换"),
            subtitle: L10n.string("连接到新的 Wi-Fi 时应用一次")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    L10n.string("根据当前 Wi-Fi 自动切换位置"),
                    isOn: Binding(
                        get: { model.autoSwitch.isEnabled },
                        set: { model.setAutoSwitchEnabled($0) }
                    )
                )
                .toggleStyle(.switch)

                if model.autoSwitch.isEnabled {
                    authorizationRow

                    HStack(spacing: 10) {
                        Text(L10n.string("当前 SSID"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(model.currentSSID ?? L10n.string("不可用"))
                            .font(.system(size: 12, weight: .semibold))
                            .fontDesign(.monospaced)
                            .textSelection(.enabled)
                    }

                    if let message = model.lastAutoSwitchMessage {
                        Text(message)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var authorizationRow: some View {
        switch model.ssidAuthorization {
        case .authorized:
            EmptyView()
        case .notDetermined:
            HStack(spacing: 10) {
                Text(L10n.string("macOS 需要定位服务权限才能读取 Wi-Fi 名称（SSID）。ToolBox 不会读取你的位置。"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L10n.string("授权定位服务")) {
                    model.requestSSIDAuthorization()
                }
            }
        case .denied:
            HStack(spacing: 10) {
                Text(L10n.string("定位服务权限被拒绝，无法读取 SSID，自动切换不会生效。"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L10n.string("打开系统设置"), action: openLocationPrivacySettings)
            }
        case .servicesDisabled:
            HStack(spacing: 10) {
                Text(L10n.string("系统定位服务已关闭，无法读取 SSID，授权弹窗也不会出现。请在系统设置中开启定位服务。"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L10n.string("打开系统设置"), action: openLocationPrivacySettings)
            }
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        SettingsSection(title: L10n.string("SSID 规则"), subtitle: L10n.string("按顺序匹配第一条")) {
            VStack(alignment: .leading, spacing: 10) {
                if model.autoSwitch.rules.isEmpty {
                    SettingsEmptyState(
                        symbolName: "wifi",
                        title: L10n.string("还没有规则"),
                        description: L10n.string("添加 SSID 与位置的对应关系，例如公司 Wi-Fi → 公司。")
                    )
                } else {
                    ForEach(model.autoSwitch.rules) { rule in
                        ruleRow(rule)
                    }
                }

                HStack(spacing: 10) {
                    TextField("SSID", text: $ruleSSID)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        ruleSSID = model.currentSSID ?? ruleSSID
                    } label: {
                        Image(systemName: "wifi")
                    }
                    .disabled(model.currentSSID == nil)
                    .help(L10n.string("填入当前 SSID"))
                    .accessibilityLabel(L10n.string("填入当前 SSID"))

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)

                    Picker(L10n.string("位置"), selection: $ruleLocation) {
                        Text(L10n.string("选择位置")).tag(String?.none)
                        ForEach(model.snapshot.locations, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)

                    Button(L10n.string("添加"), action: addRule)
                        .disabled(ruleSSID.trimmingCharacters(in: .whitespaces).isEmpty || ruleLocation == nil)
                }

                if let ruleError {
                    Text(ruleError)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                }

                Divider()

                HStack(spacing: 10) {
                    Text(L10n.string("其他 Wi-Fi"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker(
                        L10n.string("其他 Wi-Fi"),
                        selection: Binding(
                            get: { model.autoSwitch.fallbackLocation },
                            set: { model.setFallbackLocation($0) }
                        )
                    ) {
                        Text(L10n.string("保持不变")).tag(String?.none)
                        ForEach(fallbackChoices, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        }
    }

    /// Keeps a configured-but-deleted fallback selectable so the picker never
    /// renders an unmatched selection.
    private var fallbackChoices: [String] {
        var choices = model.snapshot.locations
        if let fallback = model.autoSwitch.fallbackLocation, !choices.contains(fallback) {
            choices.append(fallback)
        }
        return choices
    }

    private func ruleRow(_ rule: NetworkLocationSSIDRule) -> some View {
        SettingsInnerCard {
            HStack(spacing: 10) {
                Image(systemName: "wifi")
                    .foregroundStyle(.secondary)
                Text(rule.ssid)
                    .font(.system(size: 12, weight: .semibold))
                    .fontDesign(.monospaced)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Text(rule.location)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if !model.snapshot.locations.isEmpty, !model.snapshot.locations.contains(rule.location) {
                    Label(L10n.string("位置不存在"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                Button {
                    model.removeRule(id: rule.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L10n.string("删除规则"))
                .accessibilityLabel(L10n.string("删除规则"))
            }
        }
    }

    private func createLocation() {
        let name = newLocationName
        Task {
            if await model.createLocation(named: name) {
                newLocationName = ""
            }
        }
    }

    private func addRule() {
        do {
            try model.upsertRule(ssid: ruleSSID, location: ruleLocation ?? "")
            ruleSSID = ""
            ruleLocation = nil
            ruleError = nil
        } catch {
            ruleError = error.localizedDescription
        }
    }

    private func openLocationPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
