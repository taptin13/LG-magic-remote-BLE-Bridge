import SwiftUI
import AppKit

/// Renders the active input-device profile pad layout (data-driven).
struct RemotePadView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var appColorScheme
    @Binding var selectedCode: UInt16?
    @Binding var selectedLabel: String

    private var padDark: Bool { appColorScheme == .light }

    private var shell: Color {
        padDark ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(red: 0.93, green: 0.93, blue: 0.94)
    }
    private var face: Color {
        padDark ? Color(red: 0.18, green: 0.18, blue: 0.19) : Color(red: 0.98, green: 0.98, blue: 0.99)
    }
    private var stroke: Color {
        padDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
    }
    private var btnBase: Color {
        padDark ? Color(red: 0.24, green: 0.24, blue: 0.25) : Color(red: 0.88, green: 0.88, blue: 0.89)
    }
    private var labelPrimary: Color {
        padDark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)
    }
    private var labelSecondary: Color {
        padDark ? Color.white.opacity(0.45) : Color.black.opacity(0.45)
    }

    private var profile: InputDeviceProfile { model.activeProfile }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(profile.pad.sections.enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(shell)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(stroke.opacity(0.85), lineWidth: 1)
        )
        .environment(\.colorScheme, padDark ? .dark : .light)
    }

    private func sectionView(_ section: InputDeviceProfile.PadSection) -> AnyView {
        switch section.type {
        case "dpad":
            return AnyView(dpadSection(section))
        case "grid":
            return AnyView(gridSection(section.items ?? []))
        case "hstack":
            return AnyView(
                HStack(alignment: .center, spacing: 10) {
                    ForEach(Array((section.items ?? []).enumerated()), id: \.offset) { _, item in
                        itemView(item)
                    }
                }
            )
        case "vstack":
            return AnyView(
                VStack(spacing: 8) {
                    ForEach(Array((section.items ?? []).enumerated()), id: \.offset) { _, item in
                        itemView(item)
                    }
                }
            )
        default:
            return AnyView(EmptyView())
        }
    }

    private func itemView(_ item: InputDeviceProfile.PadItem) -> AnyView {
        switch item.kind {
        case "spacer":
            return AnyView(Spacer(minLength: 0))
        case "decorative":
            return AnyView(
                decorativeBtn(
                    item.title ?? "",
                    w: item.width ?? 44,
                    h: item.height ?? 36,
                    accent: accentColor(item.accent)
                )
            )
        case "button":
            guard let code = item.code.flatMap(HexCode.parseUInt16) else {
                return AnyView(EmptyView())
            }
            return AnyView(
                padBtn(
                    item.title ?? profile.name(for: code),
                    code: code,
                    label: item.label,
                    w: item.width ?? 56,
                    h: item.height ?? 34,
                    round: item.round ?? false,
                    flat: item.flat ?? false
                )
            )
        case "vstack":
            return AnyView(
                VStack(spacing: 8) {
                    ForEach(Array((item.items ?? []).enumerated()), id: \.offset) { _, child in
                        itemView(child)
                    }
                }
            )
        case "hstack":
            return AnyView(
                HStack(spacing: 10) {
                    ForEach(Array((item.items ?? []).enumerated()), id: \.offset) { _, child in
                        itemView(child)
                    }
                }
            )
        case "labeledColumn":
            return AnyView(
                VStack(spacing: 4) {
                    if let title = item.title {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(labelSecondary)
                    }
                    ForEach(Array((item.items ?? []).enumerated()), id: \.offset) { _, child in
                        itemView(child)
                    }
                }
            )
        default:
            return AnyView(EmptyView())
        }
    }

    private func dpadSection(_ section: InputDeviceProfile.PadSection) -> some View {
        let up = section.up.flatMap(HexCode.parseUInt16) ?? 0
        let left = section.left.flatMap(HexCode.parseUInt16) ?? 0
        let ok = section.ok.flatMap(HexCode.parseUInt16) ?? 0
        let right = section.right.flatMap(HexCode.parseUInt16) ?? 0
        let down = section.down.flatMap(HexCode.parseUInt16) ?? 0
        return ZStack {
            Circle()
                .fill(face)
                .frame(width: 168, height: 168)
                .overlay(Circle().strokeBorder(stroke, lineWidth: 1))
            VStack(spacing: 0) {
                padBtn("▲", code: up, label: profile.name(for: up), w: 56, h: 40, flat: true)
                HStack(spacing: 0) {
                    padBtn("◀", code: left, label: profile.name(for: left), w: 40, h: 56, flat: true)
                    padBtn("OK", code: ok, label: profile.name(for: ok), w: 56, h: 56, round: true)
                    padBtn("▶", code: right, label: profile.name(for: right), w: 40, h: 56, flat: true)
                }
                padBtn("▼", code: down, label: profile.name(for: down), w: 56, h: 40, flat: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func gridSection(_ items: [InputDeviceProfile.PadItem]) -> some View {
        let buttons = items.filter { $0.kind == "button" }
        return VStack(spacing: 6) {
            ForEach(0..<((buttons.count + 1) / 2), id: \.self) { row in
                HStack(spacing: 6) {
                    let start = row * 2
                    ForEach(start..<min(start + 2, buttons.count), id: \.self) { i in
                        itemView(buttons[i])
                    }
                }
            }
        }
    }

    private func accentColor(_ name: String?) -> Color {
        switch name?.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "blue": return .blue
        default: return .red
        }
    }

    private func padBtn(
        _ title: String,
        code: UInt16,
        label: String? = nil,
        w: CGFloat,
        h: CGFloat,
        round: Bool = false,
        flat: Bool = false,
        accent: Color? = nil
    ) -> some View {
        let name = label ?? title
        let isSelected = selectedCode == code
        let isLive = code == model.lastButtonCode && model.lastButtonCode != 0
        let mapped = model.keyMaps.contains { $0.buttonCode == code && $0.enabled && $0.key != 0 }

        return Button {
            tap(name: name, code: code)
        } label: {
            buttonFace(title: title, w: w, h: h, round: round, flat: flat,
                       live: isLive, selected: isSelected, mapped: mapped, accent: accent)
        }
        .buttonStyle(.plain)
        .help(helpText(name: name, code: code))
    }

    private func decorativeBtn(
        _ title: String,
        w: CGFloat,
        h: CGFloat,
        accent: Color
    ) -> some View {
        buttonFace(title: title, w: w, h: h, round: false, flat: false,
                   live: false, selected: false, mapped: false, accent: accent)
            .opacity(0.85)
            .help("\(title) — decorative only")
            .accessibilityHidden(true)
    }

    private func buttonFace(
        title: String,
        w: CGFloat,
        h: CGFloat,
        round: Bool,
        flat: Bool,
        live: Bool,
        selected: Bool,
        mapped: Bool,
        accent: Color?
    ) -> some View {
        ZStack {
            Group {
                if round {
                    Circle().fill(btnFill(live: live, selected: selected, mapped: mapped, accent: accent))
                } else {
                    RoundedRectangle(cornerRadius: flat ? 6 : 8, style: .continuous)
                        .fill(btnFill(live: live, selected: selected, mapped: mapped, accent: accent))
                }
            }
            Text(title)
                .font(.system(size: title.count > 6 ? 10 : (round ? 13 : 11), weight: .semibold))
                .foregroundStyle(accent != nil ? Color.white : labelPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: w, height: h)
        .overlay(
            Group {
                if round {
                    Circle().strokeBorder(border(selected: selected), lineWidth: selected ? 2 : 1)
                } else {
                    RoundedRectangle(cornerRadius: flat ? 6 : 8, style: .continuous)
                        .strokeBorder(border(selected: selected), lineWidth: selected ? 2 : 1)
                }
            }
        )
    }

    private func border(selected: Bool) -> Color {
        selected ? Color.accentColor : stroke.opacity(0.9)
    }

    private func btnFill(live: Bool, selected: Bool, mapped: Bool, accent: Color?) -> Color {
        if let accent { return accent }
        if live { return Color.green.opacity(padDark ? 0.40 : 0.32) }
        if selected { return Color.accentColor.opacity(padDark ? 0.32 : 0.22) }
        if mapped { return Color.accentColor.opacity(padDark ? 0.18 : 0.12) }
        return btnBase
    }

    private func helpText(name: String, code: UInt16) -> String {
        let map = model.keyMaps.first { $0.buttonCode == code }
        let preset = HIDKeyPresets.matching(mod: map?.mod ?? 0, key: map?.key ?? 0)
        return "\(name) 0x\(String(format: "%04X", code)) → \(preset.label)"
    }

    private func tap(name: String, code: UInt16) {
        selectedLabel = name
        selectedCode = code
        model.ensureMapRow(code: code, name: name)
    }
}
