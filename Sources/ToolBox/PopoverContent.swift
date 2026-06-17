import SwiftUI

struct PopoverContent: View {
    @ObservedObject var state: FeatureState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ToolBox").font(.headline)

            Toggle("擦屏幕", isOn: $state.wipeOn)
                .toggleStyle(.switch)
            Text("⌃⌥⌘ + Esc 退出").font(.caption).foregroundStyle(.secondary)

            Divider()

            Toggle("后台干", isOn: $state.awakeOn)
                .toggleStyle(.switch)
            Text("防系统睡眠 · 允许屏幕熄灭").font(.caption).foregroundStyle(.secondary)

            Divider()

            Toggle("放键盘", isOn: $state.parkOn)
                .toggleStyle(.switch)
            Text("仅锁内置键盘 · ⌃⌥⌘ + K 解锁").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 250, alignment: .leading)
    }
}
