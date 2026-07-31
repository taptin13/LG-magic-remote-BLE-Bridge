import SwiftUI

/// Layout MR25GA vẽ bằng SwiftUI (không dùng ảnh) — chạm nút để map / Learn.
struct RemotePadView: View {
    @EnvironmentObject var model: DongleModel
    @Binding var selectedCode: UInt16?
    @Binding var selectedLabel: String

    private let shell = Color(red: 0.12, green: 0.12, blue: 0.13)
    private let face = Color(red: 0.18, green: 0.18, blue: 0.19)

    var body: some View {
        VStack(spacing: 10) {
            // Top: Power (không BLE) · Help
            HStack {
                padBtn("Power", code: nil, w: 44, h: 36, accent: .red.opacity(0.85))
                Spacer()
                padBtn("Help", code: 0x808B, w: 44, h: 36)
            }

            // Input · AI · Guide
            HStack(alignment: .center, spacing: 10) {
                VStack(spacing: 8) {
                    padBtn("Input", code: 0x800B, w: 56, h: 34)
                    padBtn("Home", code: 0x807C, w: 56, h: 34)
                }
                padBtn("AI", code: nil, w: 72, h: 72, round: true)
                VStack(spacing: 8) {
                    padBtn("Guide", code: 0x8053, w: 56, h: 34)
                    padBtn("123", code: 0x8011, w: 56, h: 34)
                }
            }

            // D-pad + wheel
            ZStack {
                Circle()
                    .fill(face)
                    .frame(width: 168, height: 168)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

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

            // Vol / Ch
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("VOL").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    padBtn("+", code: 0x8002, label: "Vol+", w: 88, h: 36)
                    padBtn("−", code: 0x8003, label: "Vol-", w: 88, h: 36)
                }
                VStack(spacing: 4) {
                    Text("CH").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    padBtn("∧", code: 0x8000, label: "Ch+", w: 88, h: 36)
                    padBtn("∨", code: 0x8001, label: "Ch-", w: 88, h: 36)
                }
            }

            // App shortcuts
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    padBtn("Netflix", code: nil, w: 108, h: 32)
                    padBtn("Prime", code: nil, label: "Prime Video", w: 108, h: 32)
                }
                HStack(spacing: 6) {
                    padBtn("Disney+", code: nil, w: 108, h: 32)
                    padBtn("Rakuten", code: nil, label: "Rakuten TV", w: 108, h: 32)
                }
                HStack(spacing: 6) {
                    padBtn("LG Ch", code: nil, label: "LG Channels", w: 108, h: 32)
                    padBtn("Alexa", code: nil, w: 108, h: 32)
                }
            }
        }
        .padding(18)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(shell)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func padBtn(
        _ title: String,
        code: UInt16?,
        label: String? = nil,
        w: CGFloat,
        h: CGFloat,
        round: Bool = false,
        flat: Bool = false,
        accent: Color? = nil
    ) -> some View {
        let name = label ?? title
        let isSelected: Bool = {
            if let code, let selected = selectedCode { return code == selected }
            return selectedLabel == name && selectedCode == nil
        }()
        let isLive = code.map { $0 == model.lastButtonCode && model.lastButtonCode != 0 } ?? false
        let mapped = code.flatMap { c -> Bool? in
            if KeyMapRow.fixedMouseCodes.contains(c) { return true }
            return model.keyMaps.first { $0.buttonCode == c && $0.enabled && $0.key != 0 } != nil
        } ?? false

        return Button {
            tap(name: name, code: code)
        } label: {
            ZStack {
                Group {
                    if round {
                        Circle().fill(btnFill(live: isLive, selected: isSelected, mapped: mapped, accent: accent))
                    } else {
                        RoundedRectangle(cornerRadius: flat ? 8 : 10, style: .continuous)
                            .fill(btnFill(live: isLive, selected: isSelected, mapped: mapped, accent: accent))
                    }
                }
                Text(title)
                    .font(.system(size: title.count > 6 ? 10 : (round ? 13 : 11), weight: .semibold))
                    .foregroundStyle(accent != nil ? Color.white : Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: w, height: h)
            .overlay(
                Group {
                    if round {
                        Circle().strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                    } else {
                        RoundedRectangle(cornerRadius: flat ? 8 : 10, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .help(helpText(name: name, code: code))
    }

    private func btnFill(live: Bool, selected: Bool, mapped: Bool, accent: Color?) -> Color {
        if let accent { return accent }
        if live { return Color.green.opacity(0.55) }
        if selected { return Color.accentColor.opacity(0.45) }
        if mapped { return Color.cyan.opacity(0.22) }
        return face
    }

    private func helpText(name: String, code: UInt16?) -> String {
        if let code {
            if let mouse = KeyMapRow(buttonCode: code, buttonName: name, mod: 0, key: 0, enabled: true).fixedMouseLabel {
                return "\(name) 0x\(String(format: "%04X", code)) → \(mouse) (cố định)"
            }
            let map = model.keyMaps.first { $0.buttonCode == code }
            let preset = HIDKeyPresets.matching(mod: map?.mod ?? 0, key: map?.key ?? 0)
            return "\(name) 0x\(String(format: "%04X", code)) → \(preset.label)"
        }
        return "\(name) — Learn: bấm nút thật trên remote"
    }

    private func tap(name: String, code: UInt16?) {
        selectedLabel = name
        if let code {
            selectedCode = code
            if KeyMapRow.fixedMouseCodes.contains(code) {
                return
            }
            if !model.keyMaps.contains(where: { $0.buttonCode == code }) {
                model.keyMaps.append(KeyMapRow(
                    buttonCode: code,
                    buttonName: name,
                    mod: 0,
                    key: 0x28,
                    enabled: true
                ))
            }
        } else {
            selectedCode = nil
            model.startLearn(label: name)
            model.appendHint("Learn «\(name)»: bấm đúng nút trên remote")
        }
    }
}

extension DongleModel {
    func appendHint(_ msg: String) {
        logs.append(LogEntry(level: .info, message: msg))
    }
}
