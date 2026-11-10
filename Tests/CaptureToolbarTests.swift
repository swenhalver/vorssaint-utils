// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// The capture toolbar laid out like the system's own, and what a finished
/// recording turns into: its file name, its look, its thumbnail and where it
/// is saved and copied.
enum CaptureToolbarTests {
    static func run(_ suite: TestSuite) {
        // MARK: File names

        let utc = TimeZone(identifier: "UTC")!
        let evening = Date(timeIntervalSince1970: 1_794_253_863)
        let morning = Date(timeIntervalSince1970: 1_794_207_909)
        let prefix = RecorderFeatureStrings.enUS.fileNamePrefix
        suite.expect(prefix == "Screen Recording",
                     "recordings are named like the system's own, not plain Recording")
        suite.expect(RecorderSupport.recordingFileName(prefix: prefix, date: evening, uses12HourClock: true,
                                                       fileExtension: "mp4", timeZone: utc)
                        == "Screen Recording 2026-11-09 at 7.51.03 PM.mp4"
                     && RecorderSupport.recordingFileName(prefix: prefix, date: morning, uses12HourClock: true,
                                                          fileExtension: "mov", timeZone: utc)
                        == "Screen Recording 2026-11-09 at 7.05.09 AM.mov",
                     "a 12-hour Mac names recordings with the hour as the system does")
        suite.expect(RecorderSupport.recordingFileName(prefix: prefix, date: evening, uses12HourClock: false,
                                                       fileExtension: "mp4", timeZone: utc)
                        == "Screen Recording 2026-11-09 at 19.51.03.mp4",
                     "a 24-hour Mac keeps the 24-hour time in the name")
        suite.expect(RecorderSupport.uses12HourClock(.oneToTwelve)
                     && RecorderSupport.uses12HourClock(.zeroToEleven)
                     && !RecorderSupport.uses12HourClock(.zeroToTwentyThree)
                     && !RecorderSupport.uses12HourClock(.oneToTwentyFour),
                     "the clock follows the hour cycle the Mac reports")
        for language in AppLanguage.allCases {
            let name = FeatureStrings.recorder(language).fileNamePrefix
            suite.expect(!name.isEmpty && !name.contains("/") && !name.contains(":"),
                         "\(language.rawValue): the recording prefix is a valid file name")
        }

        // MARK: A recording saved without the editor

        let plain = RecorderEditDocument.asRecorded(quality: "high", showsClicks: false)
        suite.expect(plain.showsPointer
                     && plain.pointerSmoothing == RecorderMotion.Smoothing.off.rawValue
                     && !plain.zoomEnabled && plain.zoomSegments.isEmpty
                     && plain.backdrop.isEmpty
                     && plain.aspect == RecorderSupport.Aspect.original.rawValue
                     && !plain.showsClickRing
                     && plain.keepsSystemAudio && plain.keepsMicrophone
                     && plain.resolvedQuality == .high,
                     "a recording saved as recorded draws the pointer and adds nothing else")
        suite.expect(RecorderEditDocument.asRecorded(quality: nil, showsClicks: true).showsClickRing
                     && RecorderEditDocument.asRecorded(quality: "nonsense", showsClicks: true)
                        .resolvedQuality == .balanced,
                     "Show mouse clicks rings each click, and an unknown quality reads as balanced")

        // MARK: The floating thumbnail

        let wide = RecorderSupport.thumbnailSize(for: CGSize(width: 3840, height: 2160))
        let tall = RecorderSupport.thumbnailSize(for: CGSize(width: 800, height: 2400))
        suite.expect(wide.width <= 220 && wide.height <= 150 && abs(wide.width / wide.height - 16.0 / 9) < 0.02
                     && tall.height <= 150 && tall.width >= 48,
                     "the thumbnail keeps the recording's shape inside the corner")
        suite.expect(RecorderSupport.thumbnailSize(for: .zero) == CGSize(width: 220, height: 150),
                     "a thumbnail without a picture still has a size")
        suite.expect(!RecorderSupport.thumbnailSwipeSaves(accumulatedFingerTravel: 10)
                     && !RecorderSupport.thumbnailSwipeSaves(accumulatedFingerTravel: -80)
                     && RecorderSupport.thumbnailSwipeSaves(accumulatedFingerTravel: 40),
                     "only a real swipe toward the edge sends the thumbnail away")
        suite.expect(RecorderSupport.floatingThumbnailDuration == 5,
                     "the thumbnail waits as long as the system's before saving")

        // MARK: Save folder choices

        let home = "/Users/someone"
        let desktop = RecorderSupport.saveFolderChoices(stored: "", home: home)
        suite.expect(desktop.map(\.path) == ["/Users/someone/Desktop", "/Users/someone/Documents",
                                              "/Users/someone/Movies"]
                     && desktop.map(\.isSelected) == [true, false, false]
                     && desktop[0].storedValue.isEmpty,
                     "with no folder chosen the Desktop is the one ticked, stored as the default")
        let documents = RecorderSupport.saveFolderChoices(stored: "/Users/someone/Documents/", home: home)
        suite.expect(documents.count == 3 && documents[1].isSelected,
                     "a standard folder is ticked rather than listed twice")
        let custom = RecorderSupport.saveFolderChoices(stored: "/Volumes/Clips", home: home)
        suite.expect(custom.count == 4 && custom[3].isSelected && custom[3].storedValue == "/Volumes/Clips"
                     && !custom[0].isSelected,
                     "a folder picked in Settings stays offered and ticked")

        // MARK: Toolbar modes

        suite.expect(CaptureToolbarMode.groups(available: ScreenCaptureTool.allCases)
                        == [[.captureScreen, .captureWindow, .capturePortion],
                            [.recordScreen, .recordPortion], [.color]],
                     "the toolbar lists capture, then record, then Vorssaint's color picker; text is a button beside Markup")
        suite.expect(CaptureToolbarMode.groups(available: [.recording])
                        == [[.recordScreen, .recordPortion]],
                     "a mode without its tool installed is left off the toolbar")
        suite.expect(CaptureToolbarMode(tool: .recording, target: .window) == .recordPortion
                     && CaptureToolbarMode(tool: .screenshot, target: .window) == .captureWindow
                     && CaptureToolbarMode(tool: .text, target: .screen) == .text,
                     "every tool and target lands on a toolbar button")
        suite.expect(CaptureToolbarMode.allCases.allSatisfy {
            CaptureToolbarMode(tool: $0.tool, target: $0.target) == $0 && $0.tool.offers($0.target)
        }, "each toolbar button is a tool and target the tool offers")
        suite.expect(!CaptureToolbarMode.color.offersMarkup
                     && CaptureToolbarMode.allCases.filter { $0 != .color }.allSatisfy(\.offersMarkup),
                     "Markup is offered wherever an area, window or screen is chosen")
        func stored(_ value: String?) -> (String) -> String? { { _ in value } }
        suite.expect(ScreenCaptureTarget.remembered(for: .screenshot, stored: stored("window")) == .window
                     && ScreenCaptureTarget.remembered(for: .recording, stored: stored("window")) == .portion
                     && ScreenCaptureTarget.remembered(for: .recording, stored: stored("screen")) == .screen
                     && ScreenCaptureTarget.remembered(for: .text, stored: stored("screen")) == .portion
                     && ScreenCaptureTarget.remembered(for: .screenshot, stored: stored("bogus")) == .portion
                     && ScreenCaptureTarget.remembered(for: .screenshot, stored: stored(nil)) == .portion,
                     "the toolbar reopens on the last valid mode of each tool")

        // MARK: Toolbar placement

        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 600, height: 40)
        let start = ScreenshotSupport.captureToolbarFrame(size: size, bounds: display, stored: "")
        suite.expect(start.midX == display.midX && start.maxY == display.maxY - 32,
                     "the toolbar starts centered near the bottom, where the system's sits")
        suite.expect(ScreenshotSupport.captureToolbarFrame(size: size, bounds: display, stored: "x y") == start
                     && ScreenshotSupport.captureToolbarFrame(size: size, bounds: display, stored: "nan 1")
                        == start,
                     "an unreadable position falls back to the starting spot")
        let moved = CGRect(x: 100, y: 120, width: 600, height: 40)
        let position = ScreenshotSupport.captureToolbarStoredPosition(frame: moved, bounds: display)
        let back = ScreenshotSupport.captureToolbarFrame(size: size, bounds: display, stored: position)
        suite.expect(abs(back.minX - moved.minX) <= 1 && abs(back.minY - moved.minY) <= 1,
                     "a dragged toolbar reopens where it was left")
        let smaller = CGRect(x: 0, y: 0, width: 1024, height: 640)
        let corner = ScreenshotSupport.captureToolbarStoredPosition(
            frame: CGRect(x: 832, y: 852, width: 600, height: 40), bounds: display)
        let fitted = ScreenshotSupport.captureToolbarFrame(size: size, bounds: smaller, stored: corner)
        suite.expect(smaller.contains(fitted),
                     "on a smaller display the remembered spot still keeps the toolbar whole")
        let tiny = ScreenshotSupport.captureToolbarFrame(size: CGSize(width: 900, height: 40),
                                                         bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                                                         stored: "1 1")
        suite.expect(tiny.minX >= 0, "a toolbar wider than the display starts at its edge")
        let dragged = ScreenshotSupport.clampedCaptureToolbarOrigin(CGPoint(x: -500, y: 5000),
                                                                    size: size, bounds: display)
        suite.expect(dragged == CGPoint(x: 8, y: 900 - 40 - 8),
                     "dragging cannot push the toolbar off the display")

        // MARK: Clipboard

        for action in ScreenshotDefaultAction.allCases {
            let copied = ScreenshotSupport.effectiveDefaultAction(action, copiesToClipboard: true)
            suite.expect(action == .edit ? copied == .edit : copied == .saveAndCopy,
                         "with copying on, \(action) saves and copies the file")
            suite.expect(ScreenshotSupport.effectiveDefaultAction(action, copiesToClipboard: false) == action,
                         "with copying off, \(action) runs as chosen")
        }

        // MARK: Preferences

        let registered = Defaults.registeredDefaults
        suite.expect(registered[DefaultsKey.recorderFloatingThumbnail] as? Bool == true
                     && registered[DefaultsKey.recorderShowClicks] as? Bool == false
                     && registered[DefaultsKey.captureCopiesToClipboard] as? Bool == true
                     && registered[DefaultsKey.screenCaptureTarget] as? String == "portion"
                     && registered[DefaultsKey.recorderCaptureTarget] as? String == "portion"
                     && registered[DefaultsKey.captureToolbarPosition] as? String == "",
                     "the thumbnail and copying ship on, clicks off, and the toolbar opens on portion")
        let exported = SettingsBackupSupport.exportKeys()
        suite.expect([DefaultsKey.recorderFloatingThumbnail, DefaultsKey.recorderShowClicks,
                       DefaultsKey.captureCopiesToClipboard, DefaultsKey.screenCaptureTarget,
                       DefaultsKey.recorderCaptureTarget].allSatisfy(exported.contains),
                     "the new capture choices travel in backups")
        suite.expect(ScreenshotSupport.selectionOutlineDash.count == 2
                     && ScreenshotSupport.selectionHandleRadius >= 4,
                     "the editable area is outlined with dashes and grabbable round handles")

        // MARK: Clipboard only

        let clipboardPath = RecorderSupport.clipboardOnlyFolder.path
        suite.expect(RecorderSupport.isClipboardOnly(clipboardPath)
                     && RecorderSupport.isClipboardOnly(clipboardPath + "/")
                     && !RecorderSupport.isClipboardOnly("")
                     && !RecorderSupport.isClipboardOnly(NSHomeDirectory() + "/Desktop"),
                     "Clipboard only is recognized by its hidden folder and nothing else")
        suite.expect(clipboardPath.contains("/Caches/"),
                     "Clipboard only captures live in Caches, out of sight")

        // MARK: Strings

        for language in AppLanguage.allCases {
            let strings = FeatureStrings.captureToolbar(language)
            let values = Mirror(reflecting: strings).children.compactMap { $0.value as? String }
            suite.expect(values.count == 22 && values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                         "\(language.rawValue): every toolbar string is translated")
            suite.expect(values.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("...") },
                         "\(language.rawValue): toolbar strings follow the punctuation rules")
            suite.expect(strings.stopHint.contains("⌃⌘⎋"),
                         "\(language.rawValue): the stop hint names the system's stop keys")
        }
    }
}
