import Foundation

/// Album transfers that outlive the screen that started them.
///
/// Duplicating an album or saving one to the device is minutes of network work
/// for a long tracklist. It used to run behind a dimmed, full-screen overlay —
/// which was never protecting the *work* (those are unstructured `Task`s and
/// already survive their view being torn down), only preventing the user from
/// leaving. Moving the progress here means the screen can be left and the ring
/// still has somewhere to read from.
///
/// Serial by design. Two simultaneous uploads to one Drive account compete for
/// the same bandwidth and the same rate limit, and this app has already been on
/// the wrong end of that.
@Observable
@MainActor
final class TransferService {
    enum Kind: Equatable {
        case duplicate(providerName: String)
        case saveToDevice
        /// Tracks added to an album from edit mode's + menu — see
        /// `TransferService+AddTracks.swift`.
        case addTracks

        var verb: String {
            switch self {
            case .duplicate(let name): return "Copying to \(name)"
            case .saveToDevice: return "Saving to iPhone"
            case .addTracks: return "Adding tracks"
            }
        }

        /// Whether a second request for the same album is a repeat to drop.
        /// Adding tracks never is: each pick is different files, and picking
        /// more while the first batch uploads is exactly what running this in
        /// the background is for. They queue instead.
        var dropsRepeats: Bool { self != .addTracks }
    }

    struct Job: Identifiable {
        let id = UUID()
        /// The album's folder id, used only to reject a duplicate request.
        let albumId: String
        let albumName: String
        let kind: Kind
        var current: Int = 0
        var total: Int = 0
        /// The track or step being worked on, for the detail line.
        var detail: String = ""

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, max(0, Double(current) / Double(total)))
        }
    }

    /// Head of the list is the one actually running; the rest are waiting.
    private(set) var jobs: [Job] = []

    /// What went wrong in a background job, by album folder id, for that
    /// album's page to say. Kept here rather than in the page because the job
    /// outlives it: an upload that fails after you've left the album is
    /// reported when you come back, instead of into a view that's gone.
    var failures: [String: String] = [:]

    var active: Job? { jobs.first }
    var isBusy: Bool { !jobs.isEmpty }

    /// Continuations for jobs that are queued behind the active one.
    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Joins the queue and returns once this job is the one running. The caller
    /// must call `finish` — a `defer` at the call site — or the queue stalls.
    ///
    /// `nil` means this album already has this kind of transfer queued or
    /// running, so the request is a repeat and is dropped. The screen used to
    /// be covered while a transfer ran, which made a second tap impossible;
    /// now that it isn't, this is the thing standing between an impatient
    /// double-tap and two copies of the same album.
    func begin(albumId: String, albumName: String, kind: Kind) async -> UUID? {
        guard !kind.dropsRepeats
                || !jobs.contains(where: { $0.albumId == albumId && $0.kind == kind }) else {
            return nil
        }
        let job = Job(albumId: albumId, albumName: albumName, kind: kind)
        jobs.append(job)
        if jobs.count > 1 {
            await withCheckedContinuation { continuation in
                waiting[job.id] = continuation
            }
        }
        return job.id
    }

    func update(_ id: UUID, current: Int, total: Int, detail: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].current = current
        jobs[index].total = total
        jobs[index].detail = detail
    }

    /// Moves a job's progress forward, never back. Upload progress arrives
    /// from the network on its own schedule, and a report that lands after its
    /// file has finished would otherwise pull the ring backwards.
    func advance(_ id: UUID, to current: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              current > jobs[index].current else { return }
        jobs[index].current = current
    }

    func finish(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        waiting.removeValue(forKey: id)
        // Wake whoever is now at the head.
        if let next = jobs.first, let continuation = waiting.removeValue(forKey: next.id) {
            continuation.resume()
        }
    }
}
