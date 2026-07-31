import SwiftUI
import AppKit

/// MR25GA layout — colors inverted vs the app appearance (light app → dark pad, and vice versa).
struct RemotePadView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var appColorScheme
    @Binding var selectedCode: UInt16?
    @Binding var selectedLabel: String

    /// Pad uses the opposite of the app/window color scheme.
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

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                /* Power — decorative on pad, no Learn / no BLE. */
                decorativeBtn("Power", w: 44, h: 36, accent: .red)
                Spacer()
                padBtn("Help", code: 0x8029, w: 44, h: 36)
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(spacing: 8) {
                    padBtn("Input", code: 0x80A1, w: 56, h: 34)
                    padBtn("Home", code: 0x807C, w: 56, h: 34)
                }
                padBtn("AI", code: 0x808B, w: 72, h: 72, round: true)
                VStack(spacing: 8) {
                    padBtn("Guide", code: 0x80AB, w: 56, h: 34)
                    padBtn("123", code: 0x8045, w: 56, h: 34)
                }
            }

            ZStack {
                Circle()
                    .fill(face)
                    .frame(width: 168, height: 168)
                    .overlay(Circle().strokeBorder(stroke, lineWidth: 1))

                VStack(spacing: 0) {
                    padBtn("▲", code: 0x8040, label: "Up", w: 56, h: 40, flat: true)
                    HStack(spacing: 0) {
                        padBtn("◀", code: 0x8007, label: "Left", w: 40, h: 56, flat: true)
                        padBtn("OK", code: 0x8044, label: "Wheel/OK", w: 56, h: 56, round: true)
                        padBtn("▶", code: 0x8006, label: "Right", w: 40, h: 56, flat: true)
                    }
                    padBtn("▼", code: 0x8041, label: "Down", w: 56, h: 40, flat: true)
                }
            }
            .padding(.vertical, 4)

            HStack {
                padBtn("Back", code: 0x8028, w: 64, h: 34)
                Spacer()
                padBtn("Settings", code: 0x8043, w: 64, h: 34)
            }

            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("VOL")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(labelSecondary)
                    padBtn("+", code: 0x8002, label: "Vol+", w: 88, h: 36)
                    padBtn("−", code: 0x8003, label: "Vol-", w: 88, h: 36)
                }
                VStack(spacing: 4) {
                    Text("CH")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(labelSecondary)
                    padBtn("∧", code: 0x8000, label: "Ch+", w: 88, h: 36)
                    padBtn("∨", code: 0x8001, label: "Ch-", w: 88, h: 36)
                }
            }

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    padBtn("B1", code: 0x8056, w: 108, h: 32)
                    padBtn("B2", code: 0x8042, w: 108, h: 32)
                }
                HStack(spacing: 6) {
                    padBtn("B3", code: 0x8031, w: 108, h: 32)
                    padBtn("B4", code: 0x80A3, w: 108, h: 32)
                }
                HStack(spacing: 6) {
                    padBtn("B5", code: 0x8048, w: 108, h: 32)
                    padBtn("B6", code: 0x800C, w: 108, h: 32)
                }
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
