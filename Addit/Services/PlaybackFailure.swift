import AVFoundation
import Foundation

/// Why a track didn't play, as specifically as the failure itself says.
///
/// Every failure used to reach the screen as "Unable to play this audio
/// format", whatever it was. The commonest wasn't a format at all: play a
/// track that isn't downloaded yet, lock the phone, and iOS suspends Addit
/// with the download half done; on unlocking, the dropped connection was
/// reported as a codec Addit lacked. Each stage of a load
/// (`AudioPlayerService.loadAndPlay`) now names what it was doing when it
/// failed — fetching the file, decoding it, starting audio — and the error it
/// caught narrows that down.
struct PlaybackFailure: Identifiable {
    let id = UUID()
    let track: Track
    let reason: Reason

    enum Reason: Error, Equatable {
        /// iOS suspended Addit before the track was ready — downloaded, or
        /// converted — because it had gone into the background.
        case interruptedInBackground
        /// No connection, or it dropped mid-download.
        case offline
        /// The drive's session is gone, or its token couldn't be refreshed.
        case signedOut
        /// The drive says the file isn't there any more.
        case removedFromDrive
        /// The drive refused the download.
        case noAccess
        /// The drive is rate-limiting or failing; the status code if one came back.
        case driveTrouble(Int?)
        /// A track stored on this iPhone whose file is gone.
        case missingFile
        /// The file is here, and nothing in iOS can decode it — a format it
        /// doesn't know, or a damaged file.
        case unsupportedFormat
        /// The audio session or engine wouldn't start.
        case audioUnavailable
        /// Anything else, in the error's own words.
        case other(String)
    }

    /// Worth pressing again: the cause can clear up on its own.
    var isRetryable: Bool {
        switch reason {
        case .interruptedInBackground, .offline, .driveTrouble, .audioUnavailable, .other:
            true
        case .signedOut, .removedFromDrive, .noAccess, .missingFile, .unsupportedFormat:
            false
        }
    }

    var title: String {
        switch reason {
        case .interruptedInBackground: "Download Didn't Finish"
        case .offline: "Couldn't Download Track"
        case .signedOut: "Signed Out of \(drive)"
        case .removedFromDrive: "Track Not Found"
        case .noAccess: "Download Refused"
        case .driveTrouble: "\(drive) Didn't Respond"
        case .missingFile: "Track File Missing"
        case .unsupportedFormat: "Unable to Play This Audio Format"
        case .audioUnavailable: "Couldn't Start Audio"
        case .other: "Couldn't Play Track"
        }
    }

    var message: String {
        let name = "\u{201C}\(track.displayName)\u{201D}"
        return switch reason {
        case .interruptedInBackground:
            // On this iPhone, the only thing that can be cut short is a
            // conversion; from a drive, almost always the download.
            track.isLocal
                ? "\(name) was still being prepared when Addit went into the background, and iOS stopped it before it finished. The file itself is fine."
                : "\(name) was still being fetched from \(drive) when Addit went into the background, and iOS stopped it before it finished. The file itself is fine."
        case .offline:
            "\(name) couldn't be downloaded from \(drive): the connection dropped, or there isn't one. Check it and try again."
        case .signedOut:
            "Addit's sign-in to \(drive) has lapsed, so \(name) couldn't be downloaded. Sign in again from the account menu."
        case .removedFromDrive:
            "\(name) isn't in \(drive) any more. It may have been moved or deleted there."
        case .noAccess:
            "\(drive) wouldn't let Addit download \(name). It may no longer be shared with this account, or \(drive) is holding back downloads of it for now."
        case .driveTrouble(let status):
            "\(drive) didn't send \(name)\(status.map { " (error \($0))" } ?? ""). Try again in a moment."
        case .missingFile:
            "The audio file for \(name) isn't on this iPhone any more."
        case .unsupportedFormat:
            "\(name) isn't in an audio format Addit can decode, or the file itself is damaged."
        case .audioUnavailable:
            "iOS wouldn't let Addit start playing \(name) just then — usually because a call or another app had the audio."
        case .other(let description):
            "\(name) didn't play: \(description)"
        }
    }

    /// The same, in a few words, for the player's subtitle line.
    var summary: String {
        switch reason {
        case .interruptedInBackground: "Download stopped in the background"
        case .offline: "Couldn't download — check your connection"
        case .signedOut: "Signed out of \(drive)"
        case .removedFromDrive: "No longer in \(drive)"
        case .noAccess: "\(drive) refused the download"
        case .driveTrouble: "\(drive) didn't respond"
        case .missingFile: "Audio file missing"
        case .unsupportedFormat: "Unsupported audio format"
        case .audioUnavailable: "Couldn't start audio"
        case .other: "Couldn't play this track"
        }
    }

    private var drive: String {
        track.album?.isOneDrive == true ? "OneDrive" : "Google Drive"
    }
}

extension PlaybackFailure.Reason {
    /// What a failed download means. `suspended`: iOS took back Addit's
    /// background time while it was in flight, which is what turns a dropped
    /// connection from "check your network" into "the phone locked".
    init(downloadError error: Error, suspended: Bool) {
        if let reason = error as? Self {
            self = reason
        } else if Self.isConnectionFailure(error) {
            self = suspended ? .interruptedInBackground : .offline
        } else {
            switch error {
            case DriveError.unauthorized, DriveError.notConfigured, CacheError.notConfigured,
                 AuthError.notSignedIn, AuthError.tokenRefreshFailed, AuthError.accountMismatch,
                 MicrosoftAuthService.MSAuthError.notSignedIn,
                 MicrosoftAuthService.MSAuthError.tokenRefreshFailed,
                 MicrosoftAuthService.MSAuthError.accountMismatch,
                 OneDriveService.OneDriveError.notConfigured:
                self = .signedOut
            case DriveError.notFound:
                self = .removedFromDrive
            case DriveError.forbidden:
                self = .noAccess
            case DriveError.rateLimited:
                self = .driveTrouble(429)
            case DriveError.serverError(let status):
                self = .driveTrouble(status)
            case DriveError.invalidResponse:
                self = .driveTrouble(nil)
            case OneDriveService.OneDriveError.badResponse(let status, _):
                self = switch status {
                case 401: .signedOut
                case 403: .noAccess
                case 404, 410: .removedFromDrive
                default: .driveTrouble(status)
                }
            default:
                self = .other(error.localizedDescription)
            }
        }
    }

    /// The connection, not the request: offline, dropped, timed out, the
    /// socket torn down under a suspended app. The same request on a working
    /// connection would have gone through.
    private static func isConnectionFailure(_ error: Error) -> Bool {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .dataNotAllowed, .internationalRoamingOff, .callIsActive,
                 .secureConnectionFailed, .cancelled:
                return true
            default:
                return false
            }
        }
        let error = error as NSError
        // ECONNABORTED, ENOTCONN, ETIMEDOUT, ENETDOWN, ENETUNREACH, ECONNRESET:
        // what a suspended app's sockets come back with when it's woken.
        return error.domain == NSPOSIXErrorDomain
            && [53, 57, 60, 50, 51, 54].contains(error.code)
    }

    /// What it means when a file that arrived can't be opened even after
    /// converting it. Conversion stops on its own when the app goes into
    /// the background mid-way, which isn't the file's fault.
    init(decodeError error: Error) {
        let error = error as NSError
        self = error.domain == AVFoundationErrorDomain
            && error.code == AVError.Code.operationInterrupted.rawValue
            ? .interruptedInBackground
            : .unsupportedFormat
    }
}
