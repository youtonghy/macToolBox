import SwiftUI

/// Chinese editor for freeform external-display brightness schedules.
struct BrightnessScheduleSettingsView: View {
    @ObservedObject var coordinator: BrightnessScheduleCoordinator
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    @State private var editorError: String?
    @State private var saveError: String?
    @State private var isAddingSegment = false
    @State private var draftStart = Date()
    @State private var draftBrightness = 60

    private let accent = Color(nsColor: .systemTeal)

    var body: some View {
        SettingsSection(title: "定时亮度", subtitle: runtimeSubtitle) {
            VStack(alignment: .leading, spacing: 10) {
                if let issue = coordinator.configurationIssue {
                    inlineNotice(issue.message, accent: Color(nsColor: .systemOrange))
                }
                if let editorError {
                    inlineNotice(editorError, accent: Color(nsColor: .systemOrange))
                }
                if let saveError {
                    inlineNotice(saveError, accent: Color(nsColor: .systemRed))
                }

                SettingsInnerCard {
                    HStack(spacing: 12) {
                        SettingsIconBadge(
                            systemName: "clock.arrow.2.circlepath",
                            accent: accent,
                            emphasized: coordinator.configuration.isEnabled
                        )

                        Text("启用")
                            .font(.system(size: 13, weight: .semibold))

                        Spacer(minLength: 12)

                        Toggle(
                            "",
                            isOn: Binding(
                                get: { coordinator.configuration.isEnabled },
                                set: { setEnabled($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("定时亮度")
                    }
                }

                if coordinator.configuration.isEnabled && !launchAtLogin.isEnabled {
                    SettingsInnerCard {
                        HStack(spacing: 12) {
                            SettingsIconBadge(
                                systemName: "power.circle",
                                accent: Color(nsColor: .systemOrange),
                                emphasized: true
                            )
                            Text("开机自启动")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 8)
                            Button("开启") {
                                launchAtLogin.setEnabled(true)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color(nsColor: .systemOrange).opacity(0.16))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color(nsColor: .systemOrange).opacity(0.28), lineWidth: 1)
                            )
                            .accessibilityLabel("开启开机自启动")
                        }
                    }
                }

                VStack(spacing: 8) {
                    ForEach(Array(intervals.enumerated()), id: \.element.id) { _, interval in
                        segmentRow(interval)
                    }
                }

                HStack {
                    Spacer(minLength: 0)
                    Button {
                        beginAddSegment()
                    } label: {
                        Label("添加时段", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(canAddSegment ? accent.opacity(0.16) : Color.primary.opacity(0.06))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        canAddSegment ? accent.opacity(0.28) : Color.white.opacity(0.10),
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAddSegment)
                    .help(canAddSegment ? "添加时段" : "已无法添加更多分钟级时段")
                    .accessibilityLabel("添加时段")
                }
            }
        }
        .sheet(isPresented: $isAddingSegment) {
            addSegmentSheet
        }
    }

    // MARK: - Rows

    private func segmentRow(_ interval: BrightnessScheduleInterval) -> some View {
        let segment = coordinator.configuration.schedule.segments.first(where: { $0.id == interval.id })
        let canDelete = coordinator.configuration.schedule.segments.count > 1

        return SettingsInnerCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("开始")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { date(from: interval.startMinute) },
                                set: { updateSegment(id: interval.id, start: $0, brightness: segment?.brightnessPercent ?? interval.brightnessPercent) }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .frame(width: 84)

                        Text("→")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(endLabel(for: interval))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 72, alignment: .leading)
                    }

                    HStack(spacing: 10) {
                        Text("亮度")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ScrollWheelSlider(
                            value: Binding(
                                get: { Double(segment?.brightnessPercent ?? interval.brightnessPercent) },
                                set: { updateSegment(id: interval.id, start: date(from: interval.startMinute), brightness: Int($0.rounded())) }
                            ),
                            in: 0...100,
                            step: 1
                        )
                        .controlSize(.small)
                        Text("\(segment?.brightnessPercent ?? interval.brightnessPercent)%")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Button {
                    removeSegment(id: interval.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(canDelete ? Color(nsColor: .systemRed) : Color.secondary.opacity(0.45))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(canDelete ? Color(nsColor: .systemRed).opacity(0.12) : Color.primary.opacity(0.04))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canDelete)
                .help(canDelete ? "删除时段" : "至少保留一个时段")
                .accessibilityLabel("删除时段")
            }
        }
    }

    private var addSegmentSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加时段")
                .font(.system(size: 16, weight: .semibold))

            HStack {
                Text("开始时间")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                DatePicker("", selection: $draftStart, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
            }

            HStack {
                Text("亮度")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollWheelSlider(value: Binding(
                    get: { Double(draftBrightness) },
                    set: { draftBrightness = Int($0.rounded()) }
                ), in: 0...100, step: 1)
                Text("\(draftBrightness)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Spacer()
                Button("取消") {
                    isAddingSegment = false
                }
                .keyboardShortcut(.cancelAction)

                Button("添加") {
                    commitAddSegment()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - Actions

    private var intervals: [BrightnessScheduleInterval] {
        coordinator.configuration.schedule.intervals
    }

    private var canAddSegment: Bool {
        coordinator.configuration.schedule.suggestedInsertion(after: nil) != nil
    }

    private func setEnabled(_ enabled: Bool) {
        commit(
            BrightnessScheduleConfiguration(
                isEnabled: enabled,
                schedule: coordinator.configuration.schedule
            )
        )
    }

    private func beginAddSegment() {
        editorError = nil
        let schedule = coordinator.configuration.schedule
        let minute = schedule.suggestedInsertion(after: nil) ?? MinuteOfDay(rawValue: 0)!
        draftStart = date(from: minute)
        if let predecessor = schedule.activeSegment(at: minute) {
            draftBrightness = predecessor.brightnessPercent
        } else {
            draftBrightness = 60
        }
        isAddingSegment = true
    }

    private func commitAddSegment() {
        guard let minute = minute(from: draftStart) else { return }
        do {
            let next = try coordinator.configuration.schedule.insertingSegment(
                startMinute: minute,
                brightnessPercent: draftBrightness
            )
            commit(
                BrightnessScheduleConfiguration(
                    isEnabled: coordinator.configuration.isEnabled,
                    schedule: next
                )
            )
            isAddingSegment = false
        } catch let error as BrightnessScheduleValidationError {
            editorError = userMessage(for: error)
            isAddingSegment = false
        } catch {
            editorError = error.localizedDescription
            isAddingSegment = false
        }
    }

    private func updateSegment(id: UUID, start: Date, brightness: Int) {
        guard let minute = minute(from: start) else { return }
        let clamped = min(100, max(0, brightness))
        do {
            let next = try coordinator.configuration.schedule.updatingSegment(
                id: id,
                startMinute: minute,
                brightnessPercent: clamped
            )
            commit(
                BrightnessScheduleConfiguration(
                    isEnabled: coordinator.configuration.isEnabled,
                    schedule: next
                )
            )
        } catch let error as BrightnessScheduleValidationError {
            editorError = userMessage(for: error)
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func removeSegment(id: UUID) {
        do {
            let next = try coordinator.configuration.schedule.removingSegment(id: id)
            commit(
                BrightnessScheduleConfiguration(
                    isEnabled: coordinator.configuration.isEnabled,
                    schedule: next
                )
            )
        } catch let error as BrightnessScheduleValidationError {
            editorError = userMessage(for: error)
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func commit(_ configuration: BrightnessScheduleConfiguration) {
        do {
            try coordinator.commit(configuration)
            editorError = nil
            saveError = nil
        } catch {
            saveError = "保存失败，当前计划未更改"
            if let localized = error as? LocalizedError, let description = localized.errorDescription {
                saveError = "保存失败，当前计划未更改（\(description)）"
            }
        }
    }

    // MARK: - Copy

    private var runtimeSubtitle: String {
        switch coordinator.runtimeState {
        case .disabled:
            return "未启用"
        case .waitingForDisplays:
            return "等待显示器"
        case let .active(percent, count, _, overrideCount):
            if overrideCount > 0 {
                return "\(percent)% · \(count) 台 · \(overrideCount) 台手动"
            }
            return "\(percent)% · \(count) 台"
        }
    }

    private func endLabel(for interval: BrightnessScheduleInterval) -> String {
        if coordinator.configuration.schedule.segments.count == 1 {
            return "全天"
        }
        let time = String(format: "%02d:%02d", interval.endMinute.hour, interval.endMinute.minute)
        return interval.wrapsToNextDay ? "次日 \(time)" : time
    }

    private func userMessage(for error: BrightnessScheduleValidationError) -> String {
        switch error {
        case .duplicateStartMinute:
            return "该时间已存在，请选择其他时间"
        case .noRoomForInsertion:
            return "已无法添加更多分钟级时段"
        case .cannotRemoveLastSegment:
            return "至少保留一个时段"
        default:
            return error.errorDescription ?? "日程无效"
        }
    }

    private func inlineNotice(_ text: String, accent: Color) -> some View {
        SettingsInnerCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(accent)
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private func date(from minute: MinuteOfDay) -> Date {
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = minute.hour
        components.minute = minute.minute
        return Calendar.current.date(from: components) ?? Date()
    }

    private func minute(from date: Date) -> MinuteOfDay? {
        MinuteOfDay.minutes(from: date, calendar: .current)
    }
}
