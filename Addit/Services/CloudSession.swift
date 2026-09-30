import Foundation

/// The URLSession the cloud services talk through: one that stops using a
/// connection once it has died.
///
/// URLSession pools connections per host and hands each new request to one
/// that's already open. When that connection goes dead without being torn
/// down, it keeps doing so. Observed in a demo on 2026-09-29, from the phone's
/// own log: a hotspot flapping between Wi-Fi and cellular (1.1 s round trips,
/// 18 path migrations) killed the QUIC connection to googleapis.com — the
/// network stack logged "Socket is not connected" and repeated data stalls —
/// and every request after that was still given to it. An upload timed out,
/// the next crawled for two minutes and got no answer, and the album's sync
/// requests each waited out the full 60 seconds, which is what left its
/// loaders spinning.
///
/// There's no per-request "use a new connection", so on a timeout or a lost
/// connection this retires the whole session — anything else in flight on it
/// is left to finish — and the next request opens a fresh one. It deliberately
/// doesn't retry anything itself: whether a request can safely be sent again
/// is the caller's business (see `GoogleDriveService`'s resumable upload).
///
/// Same method names as `URLSession`, so a service swaps the type and none of
/// its call sites change.
final class CloudSession {
    private var session = CloudSession.makeSession()

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await run { try await $0.data(for: request) }
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await run { try await $0.data(from: url) }
    }

    func upload(
        for request: URLRequest, from body: Data,
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> (Data, URLResponse) {
        try await run { try await $0.upload(for: request, from: body, delegate: delegate) }
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await run { try await $0.download(for: request) }
    }

    private func run<T>(_ request: (URLSession) async throws -> T) async throws -> T {
        let current = session
        do {
            return try await request(current)
        } catch let error as URLError where Self.meansDeadConnection(error) {
            // Only the first failure on a session replaces it. Several
            // requests stuck on one dead connection all fail within a second
            // of each other; the rest must not throw away the fresh session
            // the first one just made.
            if current === session {
                current.finishTasksAndInvalidate()
                session = Self.makeSession()
            }
            throw error
        }
    }

    /// A connection that went quiet or dropped mid-request. Not "offline" or
    /// "can't reach the host": those fail on a fresh connection just the same.
    static func meansDeadConnection(_ error: URLError) -> Bool {
        error.code == .timedOut || error.code == .networkConnectionLost
    }

    private static func makeSession() -> URLSession {
        URLSession(configuration: .default)
    }
}
