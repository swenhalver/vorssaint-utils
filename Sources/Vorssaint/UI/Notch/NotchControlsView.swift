// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct NotchControlsView: View {
    @ObservedObject var service: NotchService
    let size: CGSize
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.brightnessControlEnabled) private var brightnessEnabled = false
    @Environment(\.notchBand) private var band

    var body: some View {
        let items = NotchSupport.controls()
        // Swen's island searches from a full row of its own below the top bar.
        let search = NotchService.homeHasSearch
        let levels = items.filter(\.isLevel)
        // The levels go to the island's top row with no readout: the slider
        // there already shows the level. Beside a camera that cannot split
        // them evenly they share one row below it.
        let inBand = NotchLayout.bandLevelCount(levels.count, band: band)
        let bandLevels = Array(levels.prefix(inBand))
        let belowLevels = Array(levels.dropFirst(inBand))
        let shortcuts = items.filter { !$0.isLevel && $0 != .music }
        let layout = NotchLayout.controls(hasCards: items.contains(.music), levelRow: search || !belowLevels.isEmpty, searchRow: search,
                                          shortcutCount: shortcuts.count, width: size.width, height: size.height)
        if items.isEmpty {
            NotchEmptyView(symbol: "slider.horizontal.3", message: FeatureStrings.notch(l10n.language).empty)
        } else {
            VStack(spacing: NotchLayout.rowSpacing) {
                if layout.levelRow > 0 {
                    HStack(spacing: NotchLayout.bandLevelSpacing) {
                        if search {
                            // Grown up into the gap below the top row, so it
                            // fills that strip and the rows below stay put.
                            NotchSearchField(height: NotchLayout.levelRowHeight + NotchSearchField.lift)
                                .padding(.top, -NotchSearchField.lift)
                                .frame(maxWidth: .infinity)
                        }
                        if !belowLevels.isEmpty { NotchLevelRow(levels: belowLevels) { level($0) } }
                    }
                    .frame(height: NotchLayout.levelRowHeight)
                    .frame(height: layout.levelRow, alignment: .top)
                }
                if layout.cardRow > 0 {
                    NotchMusicControlsView(notch: service, height: layout.cardRow).frame(height: layout.cardRow)
                }
                if layout.shortcutRows > 0 {
                    NotchRail(items: shortcuts, rows: layout.shortcutRows, itemWidth: NotchLayout.shortcutWidth,
                              width: size.width, spacing: NotchLayout.shortcutSpacing,
                              leastSpacing: NotchLayout.shortcutLeastSpacing, rowSpacing: layout.shortcutRowSpacing) { item in
                        shortcut(item)
                    }
                    // The tiles center their one line, and the rail rises so
                    // the icons stay level with where two lines put them.
                    .padding(.top, layout.oneLineTiles ? -NotchLayout.oneLineTileRise : 0)
                    .environment(\.notchOneLineTiles, layout.oneLineTiles)
                }
            }
            // The last tiles keep their height and run that far past the
            // page's end, into the island's bottom margin.
            .padding(.bottom, -layout.bottomTrim)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .notchBand(leading: {
                NotchBandLevels(band: band, levels: bandLevels, side: .leading) { level($0) }
            }, trailing: {
                NotchBandLevels(band: band, levels: bandLevels, side: .trailing) { level($0) }
            })
        }
    }

    @ViewBuilder private func level(_ item: NotchControlItem) -> some View {
        if item == .volume {
            NotchAudioControls(notch: service)
        } else if item == .keyboardLight {
            NotchKeyboardLightControls()
        } else if brightnessEnabled {
            NotchBrightnessControls()
        } else {
            brightnessSetup
        }
    }

    /// A narrow level keeps the sun and the way to set brightness up; a
    /// wider one has room to name it.
    private var brightnessSetup: some View {
        let settings = Button(l10n.s.menuSettings) {
            service.perform {
                SettingsRouter.shared.request(AppFeature.brightness.settingsDestination)
                (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
            }
        }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11))
        let sun = Image(systemName: "sun.max.fill").font(.system(size: 12, weight: .medium)).frame(width: 18)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                sun
                Text(FeatureStrings.notch(l10n.language).brightness).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                settings
            }
            HStack(spacing: 6) {
                sun
                settings.lineLimit(1)
                Spacer(minLength: 0)
            }
            .help(FeatureStrings.notch(l10n.language).brightness)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(FeatureStrings.notch(l10n.language).brightness)
        }
        .frame(height: 28)
    }

    @ViewBuilder private func shortcut(_ item: NotchControlItem) -> some View {
        switch item {
        case .keepAwake: NotchAwakeButton()
        case .microphone: NotchMicButton()
        case .screenshot:
            NotchActionTile(symbol: item.symbol, title: item.title(l10n)) {
                service.perform { ScreenshotService.shared.capture() }
            }
        case .markup:
            NotchActionTile(symbol: item.symbol, title: item.title(l10n)) {
                service.perform { ScreenCaptureService.shared.captureForMarkup() }
            }
        case .hide:
            NotchActionTile(symbol: item.symbol, title: item.title(l10n), active: service.islandHidden,
                            action: service.toggleIslandHidden)
        case .recording: NotchRecorderButton(service: service)
        case .speedTest:
            NotchActionTile(symbol: item.symbol, title: item.title(l10n)) { service.showMetric(.network) }
        case .panel:
            NotchActionTile(symbol: item.symbol, title: item.title(l10n)) { service.openAppPanel() }
        case .mixer:
            NotchActionTile(symbol: item.symbol, title: item.title(l10n)) { service.select(.mixer) }
        case .commandBar:
            NotchActionTile(symbol: item.symbol, title: item.title(l10n)) { service.perform { CommandBarService.shared.show() } }
        case .scratchpad:
            NotchActionTile(symbol: item.symbol, title: item.title(l10n), action: service.openScratchpad)
        case .timer: NotchTimerTile(service: service)
        case .calendar: NotchCalendarTile(service: service)
        case .volume, .brightness, .keyboardLight, .music: EmptyView()
        }
    }
}

/// Whether the home page's tiles all name themselves in one line. A timer
/// or calendar tile can put a reading above its name, so it counts as two.
enum NotchHomeLabels {
    private static var cache: (key: String, fits: Bool)?

    static func fitOneLine(in room: CGFloat) -> Bool {
        let l10n = L10n.shared
        let tiles = NotchSupport.controls().filter { !$0.isLevel && $0 != .music }
        let key = "\(l10n.language.rawValue):\(Int(room * 2)):" + tiles.map(\.rawValue).joined(separator: ",")
        if let cache, cache.key == key { return cache.fits }
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let fits = tiles.allSatisfy { item in
            item != .timer && item != .calendar
                // A name a little too wide still takes one line, drawn smaller.
                && (item.title(l10n) as NSString).size(withAttributes: [.font: font]).width * NotchActionTile.leastTitleScale <= room
        }
        cache = (key, fits)
        return fits
    }
}

extension NotchControlItem {
    func title(_ l10n: L10n) -> String {
        switch self {
        case .volume: return FeatureStrings.notch(l10n.language).volume
        case .brightness: return FeatureStrings.notch(l10n.language).brightness
        case .keyboardLight: return FeatureStrings.brightness(l10n.language).keyboardLight
        case .keepAwake: return l10n.s.keepAwakeTitle
        case .microphone: return l10n.s.micMuteName
        case .screenshot: return FeatureStrings.recentCaptures(l10n.language).screenshot
        case .recording: return FeatureStrings.recorder(l10n.language).pageTitle
        case .speedTest: return l10n.s.speedTestRun
        case .panel: return FeatureStrings.notch(l10n.language).panel
        case .mixer: return l10n.s.mixerSection
        case .commandBar: return FeatureStrings.commandBar(l10n.language).pageTitle
        case .scratchpad: return FeatureStrings.scratchpad(l10n.language).pageTitle
        case .markup: return FeatureStrings.notch(l10n.language).markup
        case .hide: return FeatureStrings.notch(l10n.language).hideActivities
        case .music: return NotchModule.music.title(l10n.language)
        case .timer: return NotchModule.timer.title(l10n.language)
        case .calendar: return NotchModule.calendar.title(l10n.language)
        }
    }
}

/// Looks like a search field and opens the Command Bar inside the island,
/// where its real field takes the keyboard.
struct NotchSearchField: View {
    /// All of the gap above the page but a sliver, which keeps the field
    /// apart from the top row's controls.
    static let lift = NotchLayout.spacing - 2
    var height: CGFloat = 28
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let placeholder = FeatureStrings.commandBar(l10n.language).searchPlaceholder
        Button {
            CommandBarService.shared.showInIsland()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(placeholder)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(placeholder)
    }
}

struct NotchAudioControls: View {
    @ObservedObject var notch: NotchService = .shared
    @ObservedObject private var mixer = AppVolumeMixer.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var level: Double? { mixer.systemOutputVolume.map { mixer.systemOutputMuted == true ? 0 : $0 } }
    private var deviceName: String {
        mixer.outputDevices.first(where: { $0.uid == mixer.currentOutputDeviceUID })?.name ?? l10n.s.mixerSystemOutputTitle
    }

    var body: some View {
        HStack(spacing: 6) {
            mute
            slider
            NotchLevelChooser(title: l10n.s.mixerSystemOutputTitle, items: outputItems)
                .accessibilityValue(deviceName)
        }
        .frame(height: 28)
        .help(mixer.outputSwitchError ?? deviceName)
    }

    /// The level this control sets is already on screen, so the island's top
    /// row stays in view instead of repeating it.
    private func adjustOutput(volume: Double? = nil, muted: Bool? = nil) {
        notch.noteOwnLevelAdjustment(.volume)
        mixer.requestOutputAdjustment(volume: volume, muted: muted)
    }

    private var mute: some View {
        Button {
            if let muted = mixer.systemOutputMuted { adjustOutput(muted: !muted) }
        } label: {
            Image(systemName: mixer.systemOutputMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(mixer.systemOutputMuted == true ? Color.red : Color.white)
                .contentTransition(.symbolEffect(.replace))
                .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: mixer.systemOutputMuted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 6))
        .disabled(mixer.systemOutputMuted == nil)
        .accessibilityLabel(mixer.systemOutputMuted == true ? l10n.s.actionUnmute : l10n.s.actionMute)
    }

    @ViewBuilder private var slider: some View {
        if let level {
            // In the island's top row the volume draws as slim as the song's
            // position bar, keeping the full height to grab it by.
            NotchLevelSlider(value: Binding(get: { level }, set: { adjustOutput(volume: $0) }),
                             label: FeatureStrings.notch(l10n.language).volume, trackThickness: 8, easesChanges: true)
                .frame(height: 24)
        } else {
            Text(l10n.s.mixerOutputUnavailable).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        }
    }

    private var outputItems: [NotchMenuItem] { Self.outputItems(mixer: mixer, notch: notch, l10n: l10n) }

    /// The outputs to choose from, and the mixer where the island has its
    /// page; the player's output button lists the same.
    static func outputItems(mixer: AppVolumeMixer, notch: NotchService, l10n: L10n) -> [NotchMenuItem] {
        var items = mixer.outputDevices.filter(\.canBeDefaultOutput).map { device in
            NotchMenuItem(title: device.name, checked: device.uid == mixer.currentOutputDeviceUID) {
                _ = mixer.setUniversalOutputDeviceUID(device.uid)
            }
        }
        if notch.modules.contains(.mixer) {
            items.append(.separator)
            items.append(NotchMenuItem(title: l10n.s.mixerSection, symbol: NotchModule.mixer.symbol) { notch.select(.mixer) })
        }
        return items
    }
}

/// A level's chooser in the island's top row: the menu's chevron alone,
/// since the slider beside it already shows the level.
private struct NotchLevelChooser: View {
    let title: String
    let items: [NotchMenuItem]

    var body: some View {
        NotchMenuButton(title: title, items: items) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// The home page's levels in the island's top row, laid out the same on the
/// island and in its Settings preview. Across a full row they share the
/// leading side evenly, after what the island adds there, and leave the
/// trailing side to the island's marks, which give way before a level
/// narrows past its narrowest. Beside a camera the first takes the leading
/// side and the second the trailing one at its full width, so the marks
/// there give way first.
struct NotchBandLevels<Level: View>: View {
    let band: NotchBand
    /// The levels the row holds, in order.
    let levels: [NotchControlItem]
    let side: HorizontalEdge
    @ViewBuilder let level: (NotchControlItem) -> Level

    var body: some View {
        if side == .leading {
            if band.besideCamera {
                if let first = levels.first { level(first).frame(maxWidth: .infinity) }
            } else {
                HStack(spacing: NotchLayout.bandLevelSpacing) {
                    ForEach(levels) { level($0).frame(minWidth: NotchLayout.bandLevelMinimumWidth, maxWidth: .infinity) }
                }
            }
        } else if band.besideCamera, levels.count > 1 {
            level(levels[1]).frame(width: band.side)
        }
    }
}

/// The levels a camera's row cannot split evenly, together in one row
/// across the island below it, each as wide as the next.
struct NotchLevelRow<Level: View>: View {
    let levels: [NotchControlItem]
    @ViewBuilder let level: (NotchControlItem) -> Level

    var body: some View {
        HStack(spacing: NotchLayout.bandLevelSpacing) {
            ForEach(levels) { level($0).frame(maxWidth: .infinity) }
        }
        .frame(height: NotchLayout.levelRowHeight)
    }
}

private struct NotchBrightnessControls: View {
    @ObservedObject private var service = BrightnessService.shared
    @ObservedObject private var l10n = L10n.shared
    private var displays: [BrightnessDisplay] { service.displays.filter { $0.isActive && $0.method != nil } }
    /// The display the brightness keys last moved, or the one picked here,
    /// so a key press moves this slider.
    private var display: BrightnessDisplay? {
        displays.first(where: { $0.id == service.focusedDisplayID }) ?? displays.first(where: \.isBuiltIn) ?? displays.first
    }

    var body: some View {
        HStack(spacing: 6) {
            glyph
            slider
            // A single display leaves nothing to choose.
            if let display, displays.count > 1 {
                NotchLevelChooser(title: FeatureStrings.notch(l10n.language).brightness,
                                  items: displayItems(current: display))
                    .accessibilityValue(display.name)
            }
        }
        .frame(height: 28)
        .help(display?.name ?? FeatureStrings.brightness(l10n.language).noDisplays)
        .onAppear { service.refresh() }
    }

    /// Volume leads with its mute button; the sun keeps that button's width
    /// so both sliders start on the same line.
    private var glyph: some View {
        Image(systemName: "sun.max.fill").font(.system(size: 12, weight: .medium)).frame(width: 18)
    }

    private func displayItems(current: BrightnessDisplay) -> [NotchMenuItem] {
        displays.map { item in
            NotchMenuItem(title: item.name, checked: item.id == current.id) { service.focusedDisplayID = item.id }
        }
    }

    @ViewBuilder private var slider: some View {
        if let display {
            NotchLevelSlider(value: Binding(get: { display.brightness }, set: {
                // The slider shows the level it sets, so neither a reading in
                // the row nor the system's indicator repeats it.
                service.setBrightness($0, for: display.id, announces: false)
            }), label: FeatureStrings.notch(l10n.language).brightness, trackThickness: 8, easesChanges: true)
                .frame(height: 24)
        } else {
            Text(FeatureStrings.brightness(l10n.language).noDisplays)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        }
    }
}

/// The keyboard light as a level beside volume and brightness. It has no
/// device to choose, so it ends on the slider.
private struct NotchKeyboardLightControls: View {
    @ObservedObject private var service = BrightnessService.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var title: String { FeatureStrings.brightness(l10n.language).keyboardLight }

    var body: some View {
        HStack(spacing: 6) {
            glyph
            slider
        }
        .frame(height: 28)
        .help(title)
        .onAppear { service.refreshKeyboardLight() }
    }

    /// The switch the panel has, where volume keeps its mute button: off,
    /// or back on at the level the light last had.
    private var glyph: some View {
        Button {
            guard let enabled = service.keyboardLightEnabled else { return }
            NotchService.shared.noteOwnLevelAdjustment(.keyboardLight)
            service.setKeyboardLightEnabled(!enabled)
        } label: {
            Image(systemName: service.keyboardLightEnabled == false ? "light.min" : "light.max")
                .font(.system(size: 12, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: service.keyboardLightEnabled)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 6))
        .disabled(service.keyboardLightEnabled == nil)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var slider: some View {
        if let level = service.keyboardLightLevel {
            NotchLevelSlider(value: Binding(get: { Double(level) }, set: {
                NotchService.shared.noteOwnLevelAdjustment(.keyboardLight)
                service.setKeyboardLightLevel(Float($0))
            }), label: title, trackThickness: 8, easesChanges: true, onEditingChanged: service.keyboardLightDragChanged)
                .frame(height: 24)
        } else {
            Text(FeatureStrings.notchEditor(l10n.language).keyboardLightUnavailable)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        }
    }
}

/// How an active tile reads. Recording and a muted microphone are states the
/// person has to notice, so they carry their own colour instead of the neutral
/// selection fill. A timer keeps the orange it has across the island.
enum NotchTileAccent {
    case selection, alert, awake, timer

    var fill: Color {
        switch self {
        case .selection: return .white
        case .alert: return .red
        case .awake: return NotchKeepAwakeColor.color(NotchKeepAwakeColor.current)
        case .timer: return .orange
        }
    }

    var glyph: Color {
        switch self {
        case .selection, .timer: return .black
        case .awake: return NotchKeepAwakeColor.glyph(NotchKeepAwakeColor.current)
        case .alert: return .white
        }
    }
}

/// A color the person picked for part of the island, stored as "#RRGGBB".
/// Empty means the part keeps its own color.
enum NotchCustomColor {
    static func value(_ raw: String) -> ColorValue? {
        raw.isEmpty ? nil : ColorValue(text: raw)
    }

    static func color(_ raw: String) -> Color? {
        guard let value = value(raw) else { return nil }
        return Color(red: value.red, green: value.green, blue: value.blue)
    }

    static func hex(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent),
                      byte(rgb.blueComponent))
    }
}

/// The closed island's optional theme: every icon, reading and notice in it
/// drawn in one color. Pictures (album art, app icons, the companion, a
/// watched area) keep their own colors, and the open island is untouched.
enum NotchTheme {
    static let defaultColor = "#5AC8FA"

    static func color(enabled: Bool, raw: String) -> Color? {
        enabled ? NotchCustomColor.color(raw) ?? NotchCustomColor.color(defaultColor) : nil
    }
}

/// Recolors what it wraps in the theme color, keeping each pixel's opacity,
/// so dimmed text stays dimmer. Wrap only views without pictures.
struct NotchThemeTint: ViewModifier {
    @AppStorage(DefaultsKey.notchThemeEnabled) private var enabled = false
    @AppStorage(DefaultsKey.notchThemeColor) private var raw = NotchTheme.defaultColor

    func body(content: Content) -> some View {
        if let color = NotchTheme.color(enabled: enabled, raw: raw) {
            // Black, then white, then the theme: every pixel takes the color
            // whatever it was drawn in.
            content.colorMultiply(.black).colorInvert().colorMultiply(color)
        } else {
            content
        }
    }
}

extension View {
    func notchThemed() -> some View { modifier(NotchThemeTint()) }
}

/// The color Keep Awake wears in the island: the cup and timer of its strip
/// and the fill of its tile. Empty means the original yellow.
enum NotchKeepAwakeColor {
    static var current: String {
        UserDefaults.standard.string(forKey: DefaultsKey.notchKeepAwakeColor) ?? ""
    }

    static func color(_ raw: String) -> Color { NotchCustomColor.color(raw) ?? .yellow }

    /// The tile's glyph sits on the fill, so a dark color takes a white one.
    static func glyph(_ raw: String) -> Color {
        guard let value = NotchCustomColor.value(raw) else { return .black }
        let luminance = 0.2126 * value.red + 0.7152 * value.green + 0.0722 * value.blue
        return luminance > 0.5 ? .black : .white
    }
}

/// A glyph in its own circle over a two-line label, the shape every shortcut
/// rail in the island shares. A live reading, such as a running timer's
/// clock, takes the first line and leaves the title one line below it.
struct NotchActionTile: View {
    let symbol: String
    let title: String
    var reading: String?
    /// A timer's reading rolls down toward zero; a stopwatch's rolls up.
    var readingCountsDown = false
    /// A shorter title for the line under a reading when `title` does not
    /// fit whole; help and VoiceOver keep `title`.
    var compactTitle: String?
    var active = false
    var accent: NotchTileAccent = .selection
    let action: () -> Void
    /// How far a title shrinks before it wraps or is cut.
    static let leastTitleScale: CGFloat = 0.85
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notchOneLineTiles) private var oneLine
    /// Redraws the tile when the Keep Awake color changes in Settings.
    @AppStorage(DefaultsKey.notchKeepAwakeColor) private var keepAwakeColor = ""
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                    .foregroundStyle(active ? accent.glyph : .white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .background(active ? accent.fill : Color.white.opacity(0.075), in: Circle())
                    .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: symbol)
                // One line is centered with its icon in the tile; two keep
                // their full room, the first line level across the row.
                label
                    .frame(maxWidth: .infinity)
                    .frame(height: oneLine ? nil : 28, alignment: .top)
            }
            .padding(.horizontal, oneLine ? NotchLayout.oneLineTileInset : 4)
            .frame(maxWidth: .infinity)
            .frame(height: NotchLayout.shortcutHeight)
            .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: active)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 14))
        .accessibilityLabel(title)
        .accessibilityValue(reading ?? "")
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(title)
    }

    @ViewBuilder private var label: some View {
        if let reading {
            VStack(spacing: 1) {
                // A later day's start with a 12-hour clock, such as Spanish
                // "dom, 10:45 p. m.", needs up to 91 pt on a 68 pt line. The
                // smaller optical size spaces its letters wider, so scaling
                // alone would still cut it off.
                Text(reading).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.7)
                    .modifier(NotchRollingDigits(value: reading, countsDown: readingCountsDown))
                ViewThatFits(in: .horizontal) {
                    readingTitle(title)
                    if let compactTitle { readingTitle(compactTitle) }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        } else {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(oneLine ? 1 : 2).multilineTextAlignment(.center)
                .minimumScaleFactor(Self.leastTitleScale)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readingTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
    }
}

/// A running timer, focus cycle or stopwatch keeps its clock on the tile:
/// opening the island covers the reading the closed island showed, and a
/// countdown hidden from the closed island can still be read here.
private struct NotchTimerTile: View {
    let service: NotchService
    @ObservedObject private var timer = NotchTimerService.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        if timer.session.isRunning {
            TimelineView(.periodic(from: Date(timeIntervalSinceNow: NotchTimerSupport.tickScheduleOffset(
                for: timer.session, at: timer.now)), by: 1)) { _ in tile }
        } else {
            tile
        }
    }

    private var tile: some View {
        let session = timer.session
        let active = session.hasSession
        return NotchActionTile(
            symbol: active ? symbol(session) : NotchControlItem.timer.symbol,
            title: active ? FeatureStrings.notchActivities(l10n.language).phase(session.phase)
                : NotchControlItem.timer.title(l10n),
            reading: active ? NotchTimerSupport.clockText(for: session, at: timer.now) : nil,
            readingCountsDown: !session.countsUp,
            // A long phase name, such as a Russian short break, would be cut
            // off on a narrow tile; the module's own title stands in.
            compactTitle: active ? NotchControlItem.timer.title(l10n) : nil,
            active: active, accent: .timer) { service.select(.timer) }
    }

    /// The compact strip's marks, without the circle the tile already draws.
    private func symbol(_ session: NotchTimerSession) -> String {
        if session.completed { return "checkmark" }
        if session.isPaused { return "pause.fill" }
        return session.countsUp ? "stopwatch" : "timer"
    }
}

/// The next appointment's start and title, so the week's agenda is a click
/// away rather than the only way to see what comes next.
private struct NotchCalendarTile: View {
    let service: NotchService
    @ObservedObject private var calendar = NotchCalendarService.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        TimelineView(.everyMinute) { context in tile(now: context.date) }
    }

    private func tile(now: Date) -> some View {
        let event = NotchCalendarSupport.tileEvent(calendar.events, now: now)
        let title = event?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return NotchActionTile(
            symbol: NotchControlItem.calendar.symbol,
            title: title.map { $0.isEmpty ? FeatureStrings.notchCalendar(l10n.language).untitled : $0 }
                ?? NotchControlItem.calendar.title(l10n),
            reading: event.map {
                NotchCalendarSupport.tileStartText($0.start, now: now, locale: l10n.language.formattingLocale())
            }) { service.select(.calendar) }
    }
}

private struct NotchAwakeButton: View {
    @ObservedObject private var service = KeepAwakeManager.shared
    @ObservedObject private var l10n = L10n.shared
    var body: some View {
        NotchActionTile(symbol: service.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                        title: l10n.s.keepAwakeTitle, active: service.isActive,
                        accent: .awake, action: service.toggle)
    }
}

private struct NotchMicButton: View {
    @ObservedObject private var service = MicMuteService.shared
    @ObservedObject private var l10n = L10n.shared
    var body: some View {
        NotchActionTile(symbol: service.isMuted ? "mic.slash.fill" : "mic.fill",
                        title: service.isMuted ? l10n.s.micUnmuteName : l10n.s.micMuteName,
                        active: service.isMuted, accent: .alert, action: service.toggle)
    }
}

private struct NotchRecorderButton: View {
    let service: NotchService
    @ObservedObject private var recorder = ScreenRecorderService.shared
    @ObservedObject private var l10n = L10n.shared
    var body: some View {
        NotchActionTile(symbol: recorder.isRecording ? "stop.circle.fill" : "record.circle",
                        title: FeatureStrings.recorder(l10n.language).pageTitle,
                        active: recorder.isRecording, accent: .alert) {
            service.perform { recorder.toggle() }
        }
    }
}
