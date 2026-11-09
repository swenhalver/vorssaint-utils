// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct KeepAwakeIconPicker: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.menuBarIconSymbol) private var menuBarSymbol = ""
    // Redraw the custom and theme swatches when their colors change.
    @AppStorage(DefaultsKey.keepAwakeIconCustomColor) private var customColor = ""
    @AppStorage(DefaultsKey.notchThemeColor) private var themeColor = NotchTheme.defaultColor
    @Binding var iconValue: String
    @Binding var tintValue: String
    var compact = false

    private var selectedIcon: KeepAwakeActiveIcon {
        Defaults.sanitizedKeepAwakeActiveIcon(iconValue)
    }

    private var selectedTint: KeepAwakeIconTint {
        Defaults.sanitizedKeepAwakeIconTint(tintValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            choiceHeader(l10n.s.keepAwakeActiveIconLabel,
                         value: title(selectedIcon))

            HStack(spacing: compact ? 5 : 7) {
                ForEach(KeepAwakeActiveIcon.allCases) { icon in
                    iconButton(icon)
                }
            }

            choiceHeader(l10n.s.keepAwakeIconTintLabel,
                         value: selectedTint.title(l10n.s))

            HStack(spacing: compact ? 6 : 8) {
                ForEach(KeepAwakeIconTint.allCases) { tint in
                    tintButton(tint)
                }
            }
        }
        .padding(compact ? 8 : 0)
        .background {
            if compact {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.secondary.opacity(0.055))
            }
        }
    }

    private func choiceHeader(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: compact ? 10.5 : 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: compact ? 10 : 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func iconButton(_ icon: KeepAwakeActiveIcon) -> some View {
        let selected = icon == selectedIcon
        return Button {
            iconValue = icon.rawValue
        } label: {
            Group {
                if let image = BlackHoleGlyph.activeImage(style: icon, tint: selectedTint) {
                    Image(nsImage: image)
                        .renderingMode(selectedTint == .none ? .template : .original)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: 21, maxHeight: compact ? 14 : 16)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 29 : 35)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14)
                                   : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.75)
                                           : Color.secondary.opacity(0.13),
                                  lineWidth: selected ? 1.2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title(icon))
        .accessibilityLabel(title(icon))
    }

    /// The Vorssaint choice draws whatever the menu bar shows, which can be a
    /// symbol chosen in the menu bar settings.
    private func title(_ icon: KeepAwakeActiveIcon) -> String {
        guard icon == .vorssaint,
              BlackHoleGlyph.customMark(named: Defaults.sanitizedMenuBarIconSymbol(menuBarSymbol)) != nil
        else { return icon.title(l10n.s) }
        return FeatureStrings.generalSettings(l10n.language).menuBarIconTitle
    }

    private func tintButton(_ tint: KeepAwakeIconTint) -> some View {
        let selected = tint == selectedTint
        return Button {
            tintValue = tint.rawValue
            if tint == .custom { KeepAwakeCustomColorPanel.shared.show() }
        } label: {
            ZStack {
                if tint == .custom {
                    // A color wheel until a color is chosen, then that color
                    // in a rainbow ring. Clicking it opens the color panel.
                    Circle()
                        .strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                      center: .center), lineWidth: 2.2)
                        .frame(width: compact ? 14 : 16, height: compact ? 14 : 16)
                    if !customColor.isEmpty, let color = tintColor(tint) {
                        Circle().fill(color).frame(width: compact ? 8 : 9, height: compact ? 8 : 9)
                    }
                } else if tint == .theme, let color = tintColor(tint) {
                    Circle()
                        .fill(color)
                        .frame(width: compact ? 12 : 14, height: compact ? 12 : 14)
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: compact ? 6.5 : 7.5, weight: .bold))
                        .foregroundStyle(.black.opacity(0.55))
                } else if let color = tintColor(tint) {
                    Circle()
                        .fill(color)
                        .frame(width: compact ? 12 : 14, height: compact ? 12 : 14)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1.2)
                        .frame(width: compact ? 12 : 14, height: compact ? 12 : 14)
                    // "slash" is not a symbol the system has, so the bar
                    // across the circle was never drawn: the choice for no
                    // icon showed an empty ring.
                    Image(systemName: "line.diagonal")
                        .font(.system(size: compact ? 8 : 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 24 : 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.clear,
                                  lineWidth: 1.1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tint.title(l10n.s))
        .accessibilityLabel(tint.title(l10n.s))
    }

    private func tintColor(_ tint: KeepAwakeIconTint) -> Color? {
        tint.nsColor.map { Color(nsColor: $0) }
    }
}

extension KeepAwakeIconTint {
    /// The color the menu bar icon takes; nil draws it as a plain template.
    var nsColor: NSColor? {
        switch self {
        case .orange: return .systemOrange
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .custom:
            return Self.color(hex: UserDefaults.standard.string(forKey: DefaultsKey.keepAwakeIconCustomColor))
                ?? .systemOrange
        case .theme:
            return Self.color(hex: UserDefaults.standard.string(forKey: DefaultsKey.notchThemeColor))
                ?? Self.color(hex: NotchTheme.defaultColor)
        case .none: return nil
        }
    }

    private static func color(hex: String?) -> NSColor? {
        guard let hex, !hex.isEmpty, let value = ColorValue(text: hex) else { return nil }
        return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
    }
}

/// The system color panel for the custom icon color. It writes each change
/// straight to the preference, so it keeps working after the menu closes.
@MainActor
final class KeepAwakeCustomColorPanel: NSObject {
    static let shared = KeepAwakeCustomColorPanel()

    func show() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = KeepAwakeIconTint.custom.nsColor ?? .systemOrange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        let hex = String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent),
                         byte(rgb.blueComponent))
        UserDefaults.standard.set(hex, forKey: DefaultsKey.keepAwakeIconCustomColor)
        UserDefaults.standard.set(KeepAwakeIconTint.custom.rawValue, forKey: DefaultsKey.keepAwakeIconTint)
    }
}
