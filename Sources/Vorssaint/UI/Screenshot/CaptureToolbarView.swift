// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import SwiftUI

/// The capture toolbar, laid out like the one macOS opens with
/// Command-Shift-5: close, the three capture modes, the two record modes,
/// then Vorssaint's own text and color tools, Options, Markup and the button
/// that takes the shot. Dragging its background moves it; the overlay keeps
/// it on the display and remembers where it was left.
struct CaptureToolbarView: View {
    @ObservedObject var options: ScreenCaptureSelectionOptions
    @ObservedObject private var l10n = L10n.shared
    @State private var hovered: String?
    @Environment(\.colorScheme) private var colorScheme

    private var strings: CaptureToolbarStrings { FeatureStrings.captureToolbar(l10n.language) }

    /// In dark mode the bar is the system toolbar's near black with no
    /// outline (measured from Command-Shift-5); light mode keeps the material.
    private var matchesSystemDarkBar: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 2) {
            iconButton(id: "close", symbol: "xmark.circle.fill", help: strings.closeButton,
                       selected: false, tint: .secondary) {
                options.onToolbarAction?(.close)
            }
            ForEach(Array(CaptureToolbarMode.groups(available: options.availableTools).enumerated()),
                    id: \.offset) { _, group in
                separator
                ForEach(group, id: \.self) { mode in
                    iconButton(id: mode.rawValue, symbol: mode.systemImageName, help: title(of: mode),
                               selected: options.mode == mode, tint: .primary) {
                        options.select(mode)
                    }
                    .accessibilityAddTraits(options.mode == mode ? .isSelected : [])
                }
            }
            separator
            if options.selectedTool.offersOptions {
                optionsButton
            }
            if options.mode.offersMarkup, options.availableTools.contains(.screenshot) {
                iconButton(id: "markup", symbol: "pencil.tip.crop.circle", help: strings.markupButton,
                           selected: false, tint: .primary) {
                    options.onToolbarAction?(.markup)
                }
            }
            if options.selectedTool != .color {
                primaryButton
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            if matchesSystemDarkBar {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.sRGB, red: 0x0C / 255.0, green: 0x0F / 255.0, blue: 0x11 / 255.0))
            } else {
                CaptureChromeBackdrop(material: .regularMaterial,
                                      shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .overlay {
            if !matchesSystemDarkBar {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Window coordinates: the panel never moves, so the translation stays
        // steady while the toolbar itself follows it.
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { options.onToolbarDrag?($0.translation) }
            .onEnded { _ in options.onToolbarDrag?(nil) })
        .fixedSize()
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 6)
    }

    private func title(of mode: CaptureToolbarMode) -> String {
        switch mode {
        case .captureScreen: return strings.captureScreen
        case .captureWindow: return strings.captureWindow
        case .capturePortion: return strings.capturePortion
        case .recordScreen: return strings.recordScreen
        case .recordPortion: return strings.recordPortion
        case .text, .color: return mode.tool.settingsTitle(l10n.s, language: l10n.language)
        }
    }

    private func iconButton(id: String, symbol: String, help: String, selected: Bool,
                            tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 42, height: 36)
                .background(Color.primary.opacity(selected ? 0.18 : hovered == id ? 0.08 : 0),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .help(help)
        .accessibilityLabel(help)
    }

    private var optionsButton: some View {
        Button {
            options.showsOptions.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(strings.optionsButton)
                    .font(.system(size: 14))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color.primary.opacity(options.showsOptions ? 0.18 : hovered == "options" ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? "options" : (hovered == "options" ? nil : hovered) }
        .accessibilityLabel(strings.optionsButton)
    }

    private var primaryButton: some View {
        Button {
            options.onToolbarAction?(.confirm)
        } label: {
            Text(options.selectedTool == .recording ? strings.recordButton : strings.captureButton)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(
                    // The flat, bright blue of Command-Shift-5's Capture button
                    // (measured from the system toolbar), a touch lighter under
                    // the pointer.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.sRGB, red: 0, green: 0x99 / 255.0, blue: 0xFC / 255.0))
                        .brightness(hovered == "primary" ? 0.06 : 0))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
        .onHover { hovered = $0 ? "primary" : (hovered == "primary" ? nil : hovered) }
        .help("Return")
    }
}

/// The toolbar's Options menu. It is drawn inside the capture surface rather
/// than as a real menu: the surface sits above every menu level, so a real
/// one would open underneath it. It lists the system recorder's choices
/// first, then the few Vorssaint choices worth having at hand; the rest stay
/// in Settings.
struct CaptureOptionsCard: View {
    @ObservedObject var options: ScreenCaptureSelectionOptions
    @ObservedObject private var audio: RecorderSelectionAudioOptions
    @ObservedObject private var l10n = L10n.shared
    @State private var hovered: String?

    @AppStorage(DefaultsKey.screenshotSaveFolder) private var screenshotFolder = ""
    @AppStorage(DefaultsKey.recorderSaveFolder) private var recorderFolder = ""
    @AppStorage(DefaultsKey.recorderCountdown) private var recorderCountdown = 3
    @AppStorage(DefaultsKey.screenshotPreviewEnabled) private var screenshotThumbnail = true
    @AppStorage(DefaultsKey.recorderFloatingThumbnail) private var recorderThumbnail = true
    @AppStorage(DefaultsKey.screenshotAdjustSelection) private var remembersSelection = false
    @AppStorage(DefaultsKey.recorderShowClicks) private var showsClicks = false
    @AppStorage(DefaultsKey.captureCopiesToClipboard) private var copiesToClipboard = true
    @AppStorage(DefaultsKey.recorderOpenEditor) private var opensEditor = true
    @AppStorage(DefaultsKey.recorderAutomaticZoom) private var automaticZoom = true

    init(options: ScreenCaptureSelectionOptions) {
        self.options = options
        audio = options.recorderAudio
    }

    private var strings: CaptureToolbarStrings { FeatureStrings.captureToolbar(l10n.language) }
    private var recorderStrings: RecorderFeatureStrings { FeatureStrings.recorder(l10n.language) }
    private var tool: ScreenCaptureTool { options.selectedTool }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tool == .screenshot || tool == .recording {
                section(recorderStrings.folderLabel) {
                    row(id: "folder-clipboard-only", title: strings.clipboardOnlyChoice, checked: clipboardOnly) {
                        let stored = RecorderSupport.clipboardOnlyFolder.path
                        if tool == .recording { recorderFolder = stored } else { screenshotFolder = stored }
                        copiesToClipboard = true
                    }
                    ForEach(folderChoices, id: \.path) { choice in
                        row(id: "folder-\(choice.path)",
                            title: FileManager.default.displayName(atPath: choice.path),
                            checked: choice.isSelected) {
                            if tool == .recording {
                                recorderFolder = choice.storedValue
                            } else {
                                screenshotFolder = choice.storedValue
                            }
                        }
                    }
                }
            }
            // The recorder's countdown runs after Record, as on macOS. The
            // screenshot delay runs before this surface opens, so it stays in
            // Settings rather than promising a timer this Capture won't run.
            if tool == .recording {
                section(strings.timerLabel) {
                    ForEach(ScreenshotSupport.allowedDelays, id: \.self) { seconds in
                        row(id: "timer-\(seconds)",
                            title: seconds == 0
                                ? strings.timerNone
                                : String(format: recorderStrings.countdownSecondsFormat, seconds),
                            checked: timer == seconds) {
                            recorderCountdown = seconds
                        }
                    }
                }
            }
            if tool == .recording {
                section(recorderStrings.microphoneTrackLabel) {
                    row(id: "mic-none", title: strings.timerNone, checked: !audio.microphone) {
                        audio.microphone = false
                    }
                    row(id: "mic-on", title: microphoneName, checked: audio.microphone) {
                        audio.microphone = true
                    }
                }
            }
            section(strings.optionsButton) {
                if tool == .screenshot || tool == .recording {
                    row(id: "thumbnail", title: strings.floatingThumbnailToggle, checked: thumbnail) {
                        if tool == .recording { recorderThumbnail.toggle() } else { screenshotThumbnail.toggle() }
                    }
                }
                row(id: "remember", title: strings.rememberSelectionToggle, checked: remembersSelection) {
                    remembersSelection.toggle()
                }
                if tool == .recording {
                    row(id: "clicks", title: strings.showClicksToggle, checked: showsClicks) {
                        showsClicks.toggle()
                    }
                }
                if tool == .screenshot || tool == .recording {
                    // Clipboard only is pointless without the copy, so it stays on.
                    row(id: "clipboard", title: strings.copyToClipboardToggle,
                        checked: copiesToClipboard || clipboardOnly) {
                        if !clipboardOnly { copiesToClipboard.toggle() }
                    }
                }
            }
            if tool == .recording {
                // Vorssaint's own: what Apple's recorder cannot do.
                section("Vorssaint") {
                    row(id: "sound", title: recorderStrings.systemAudioToggle, checked: audio.systemAudio) {
                        audio.systemAudio.toggle()
                    }
                    row(id: "zoom", title: recorderStrings.automaticZoomToggle, checked: automaticZoom) {
                        automaticZoom.toggle()
                    }
                    if !recorderThumbnail {
                        row(id: "editor", title: recorderStrings.openEditorToggle, checked: opensEditor) {
                            opensEditor.toggle()
                        }
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 270, alignment: .leading)
        .background(CaptureChromeBackdrop(
            material: .regularMaterial,
            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var storedFolder: String { tool == .recording ? recorderFolder : screenshotFolder }

    private var clipboardOnly: Bool { RecorderSupport.isClipboardOnly(storedFolder) }

    /// The hidden clipboard folder is not a folder to list: with it chosen,
    /// only the Clipboard only row is checked.
    private var folderChoices: [RecorderSupport.SaveFolderChoice] {
        let choices = RecorderSupport.saveFolderChoices(
            stored: storedFolder, home: FileManager.default.homeDirectoryForCurrentUser.path)
        guard clipboardOnly else { return choices }
        return choices
            .filter { !RecorderSupport.isClipboardOnly($0.path) }
            .map { RecorderSupport.SaveFolderChoice(storedValue: $0.storedValue, path: $0.path, isSelected: false) }
    }

    private var timer: Int { ScreenshotSupport.sanitizedDelay(recorderCountdown) }

    private var thumbnail: Bool { tool == .recording ? recorderThumbnail : screenshotThumbnail }

    private var microphoneName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? recorderStrings.microphoneTrackLabel
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            content()
        }
    }

    private func row(id: String, title: String, checked: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(checked ? 1 : 0)
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovered == id ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(hovered == id ? Color.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}
