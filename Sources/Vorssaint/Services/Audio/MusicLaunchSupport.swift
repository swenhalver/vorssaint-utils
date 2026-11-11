// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// An automatic music-app launch is blocked only on positive evidence: an
/// observed media key, or the system's own record that it opened the app for
/// a media command (headphones, AirPods, Control Center). Absence of a click
/// is not evidence: voice, automation and login can all open an app
/// intentionally without a keyboard or pointer gesture.
enum MusicLaunchSupport {
    static let systemDefinedEventTypeRawValue: UInt32 = 14
    static let auxiliaryControlButtonsSubtype = 8
    static let keyDownState = 10
    /// Launch Services needs a moment after the key to start the app.
    static let launchArmWindow: TimeInterval = 2.0
    static let playPauseKeyCode: UInt16 = 16
    static let nextTrackKeyCode: UInt16 = 17
    static let previousTrackKeyCode: UInt16 = 18
    static let fastForwardKeyCode: UInt16 = 19
    static let rewindKeyCode: UInt16 = 20

    static let musicLaunchKeyCodes: Set<UInt16> = [
        playPauseKeyCode, nextTrackKeyCode, previousTrackKeyCode,
        fastForwardKeyCode, rewindKeyCode
    ]

    /// A player opened in place of the music app gets this long to finish
    /// launching, then this long to settle before it is asked to play.
    static let replacementLaunchTimeout: TimeInterval = 15
    static let replacementSettleDelay: TimeInterval = 1
    static let playbackAttempts = 3

    /// True for the key-down of a media key that would otherwise open the
    /// music app. Releases, auto-repeat and volume or brightness keys do not
    /// count, so those never arm the blocker.
    static func isMusicLaunchTrigger(subtype: Int, data1: Int) -> Bool {
        guard subtype == auxiliaryControlButtonsSubtype else { return false }
        let raw = UInt32(truncatingIfNeeded: data1)
        let state = Int((raw >> 8) & 0xFF)
        guard state == keyDownState, (raw & 0x1) == 0 else { return false }
        return musicLaunchKeyCodes.contains(keyCode(data1: data1))
    }

    static func keyCode(data1: Int) -> UInt16 {
        UInt16((UInt32(truncatingIfNeeded: data1) >> 16) & 0xFFFF)
    }

    /// procNotFound and connectionInvalid: the player was not listening yet,
    /// so the command never arrived and asking again cannot play twice. Any
    /// other failure, a timeout included, may follow delivery.
    static func playbackNeverArrived(_ status: Int) -> Bool {
        status == -600 || status == -609
    }

    /// A newer click or key press takes precedence over a media key. Invalid
    /// or expired evidence always leaves the launch alone. An infinite gesture
    /// age means the session has never seen one, and still needs a real key.
    static func shouldBlockLaunch(now: TimeInterval,
                                  lastTriggerAt: TimeInterval?,
                                  secondsSinceUserGesture: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0, let lastTriggerAt,
              lastTriggerAt.isFinite, lastTriggerAt >= 0,
              !secondsSinceUserGesture.isNaN, secondsSinceUserGesture >= 0 else { return false }
        let elapsed = now - lastTriggerAt
        return (0...launchArmWindow).contains(elapsed) && secondsSinceUserGesture > elapsed
    }

    /// How far apart the system's launch request and the launch itself may
    /// be seen. The log can arrive before or after the launch notification.
    static let commandLaunchWindow: TimeInterval = 3

    /// mediaremoted logs this line when a media command finds no player and
    /// asks Launch Services to open one, e.g.
    /// `Request: MRDLaunchApplicationWithReason<command<Play>=…> for com.apple.Music`.
    static let commandLaunchMarker = "Request: MRDLaunchApplicationWithReason<"
    static let commandLaunchLogPredicate =
        "process == \"mediaremoted\" AND eventMessage CONTAINS \"\(commandLaunchMarker)\""

    /// The app a logged media command asked to open, and whether that
    /// command was a request to play. Nil for any other line.
    static func commandLaunch(in line: String) -> (bundleID: String, plays: Bool)? {
        guard let marker = line.range(of: commandLaunchMarker),
              let target = line.range(of: " for ", options: .backwards, range: marker.upperBound..<line.endIndex)
        else { return nil }
        let bundleID = line[target.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty, !bundleID.contains(" ") else { return nil }
        let reason = line[marker.upperBound..<target.lowerBound]
        var command = ""
        if let start = reason.range(of: "command<"),
           let end = reason[start.upperBound...].firstIndex(of: ">") {
            command = String(reason[start.upperBound..<end])
        }
        return (bundleID, command == "Play" || command == "TogglePlayPause")
    }

    /// A launch and a logged media-command request belong together when
    /// they are seen within the window of each other, in either order.
    static func isCommandLaunch(launchAt: TimeInterval, requestAt: TimeInterval) -> Bool {
        guard launchAt.isFinite, requestAt.isFinite else { return false }
        return abs(launchAt - requestAt) <= commandLaunchWindow
    }
}
