import AppKit
import Combine
import Foundation
import SwiftUI

struct AppleMusicTrackInfo: Equatable {
    enum Identity: Equatable {
        case persistentID(String)
        case metadata(title: String?, album: String?, artist: String?, durationSeconds: Int?)
    }

    let persistentID: String?
    let title: String?
    let album: String?
    let artist: String?
    /// Library metadata reported by Music. This is not the active streaming bitrate.
    let libraryBitrateKbps: Int?
    let sampleRateHz: Int?
    let musicKind: String?
    let durationSeconds: TimeInterval?

    var identity: Identity {
        if let persistentID {
            return .persistentID(persistentID)
        }
        return .metadata(
            title: title,
            album: album,
            artist: artist,
            durationSeconds: durationSeconds.map { Int($0.rounded()) }
        )
    }
}

enum AppleMusicNowPlayingState: Equatable {
    case checking
    case playing(AppleMusicTrackInfo)
    case musicNotRunning
    case nothingPlaying
    case accessDenied
    case unavailable
}

@MainActor
final class AppleMusicNowPlayingProvider: ObservableObject {
    @Published private(set) var state = AppleMusicNowPlayingState.checking

    private static let musicBundleIdentifier = "com.apple.Music"
    private let queryQueue = DispatchQueue(label: "com.arbisoft.peq.apple-music-metadata", qos: .utility)
    private var timer: Timer?
    private var generation = 0
    private var requestInFlight = false

    func start() {
        guard timer == nil else { return }
        generation += 1
        state = .checking
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        requestInFlight = false
    }

    private func refresh() {
        guard timer != nil || state == .checking, !requestInFlight else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleIdentifier).isEmpty else {
            state = .musicNotRunning
            return
        }

        requestInFlight = true
        let requestGeneration = generation
        queryQueue.async { [weak self] in
            let result = Self.queryAppleMusic()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == requestGeneration else { return }
                    self.requestInFlight = false
                    self.state = result
                }
            }
        }
    }

    private nonisolated static func queryAppleMusic() -> AppleMusicNowPlayingState {
        let source = """
        tell application id "com.apple.Music"
            if player state is stopped then return {"not-playing"}
            set activeTrack to current track
            set trackTitle to name of activeTrack
            set trackAlbum to album of activeTrack
            set trackArtist to artist of activeTrack
            set trackDuration to duration of activeTrack
            try
                set trackBitrate to bit rate of activeTrack
            on error
                set trackBitrate to 0
            end try
            try
                set trackSampleRate to sample rate of activeTrack
            on error
                set trackSampleRate to 0
            end try
            try
                set trackKind to kind of activeTrack
            on error
                set trackKind to ""
            end try
            try
                set trackPersistentID to persistent ID of activeTrack
            on error
                set trackPersistentID to ""
            end try
            return {"playing", trackTitle, trackAlbum, trackArtist, trackDuration, trackBitrate, trackSampleRate, trackKind, trackPersistentID}
        end tell
        """

        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            if let code = error?[NSAppleScript.errorNumber] as? NSNumber, code.intValue == -1743 {
                return .accessDenied
            }
            return .unavailable
        }

        guard descriptor.numberOfItems > 0,
              let status = descriptor.atIndex(1)?.stringValue else {
            return .unavailable
        }
        guard status == "playing" else { return .nothingPlaying }

        let title = nonEmptyString(from: descriptor.atIndex(2))
        let album = nonEmptyString(from: descriptor.atIndex(3))
        let artist = nonEmptyString(from: descriptor.atIndex(4))
        let duration = positiveDouble(from: descriptor.atIndex(5))
        let bitrate = positiveInt(from: descriptor.atIndex(6))
        let sampleRate = positiveInt(from: descriptor.atIndex(7))
        let kind = nonEmptyString(from: descriptor.atIndex(8))
        let persistentID = nonEmptyString(from: descriptor.atIndex(9))
        return .playing(AppleMusicTrackInfo(
            persistentID: persistentID,
            title: title,
            album: album,
            artist: artist,
            libraryBitrateKbps: bitrate,
            sampleRateHz: sampleRate,
            musicKind: kind,
            durationSeconds: duration
        ))
    }

    private nonisolated static func positiveDouble(from descriptor: NSAppleEventDescriptor?) -> Double? {
        guard let descriptor else { return nil }
        let value = descriptor.doubleValue
        return value.isFinite && value > 0 ? value : nil
    }

    private nonisolated static func positiveInt(from descriptor: NSAppleEventDescriptor?) -> Int? {
        guard let value = positiveDouble(from: descriptor), value <= Double(Int.max) else { return nil }
        return Int(value.rounded())
    }

    private nonisolated static func nonEmptyString(from descriptor: NSAppleEventDescriptor?) -> String? {
        guard let value = descriptor?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

struct AppleMusicTrackInfoView: View {
    let state: AppleMusicNowPlayingState

    var body: some View {
        Group {
            switch state {
            case .playing(let track):
                VStack(spacing: 10) {
                    if let title = track.title {
                        Text(title)
                            .font(.system(size: 38, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    if let artist = track.artist {
                        Text(artist)
                            .font(.system(size: 34, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                    if let album = track.album {
                        Text(album)
                            .font(.system(size: 26, weight: .light, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    if let sampleRate = Self.sampleRateText(track.sampleRateHz),
                       let duration = Self.durationText(track.durationSeconds) {
                        HStack(spacing: 28) {
                            metadata(sampleRate)
                            Text("-").font(.system(size: 24, weight: .regular, design: .monospaced)).foregroundStyle(.white.opacity(0.28))
                            metadata(duration)
                        }
                        .padding(.top, 8)
                    } else if let sampleRate = Self.sampleRateText(track.sampleRateHz) {
                        metadata(sampleRate)
                            .padding(.top, 8)
                    } else if let duration = Self.durationText(track.durationSeconds) {
                        metadata(duration)
                            .padding(.top, 8)
                    }
                }
            case .checking, .musicNotRunning, .nothingPlaying, .accessDenied, .unavailable:
                EmptyView()
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.55)
        .padding(.horizontal, 60)
    }

    private func metadata(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 24, weight: .regular, design: .monospaced))
            .foregroundStyle(.white.opacity(0.28))
    }

    private static func durationText(_ duration: TimeInterval?) -> String? {
        guard let duration else { return nil }
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func sampleRateText(_ sampleRateHz: Int?) -> String? {
        guard let sampleRateHz, sampleRateHz > 0 else { return nil }
        let sampleRateKHz = Double(sampleRateHz) / 1_000
        if sampleRateHz.isMultiple(of: 1_000) {
            return String(format: "%.0f kHz", sampleRateKHz)
        }
        return String(format: "%.1f kHz", sampleRateKHz)
    }
}
