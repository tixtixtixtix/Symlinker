import AppKit
import Foundation
import UniformTypeIdentifiers

enum SelectionRole: String, Hashable, Sendable, CaseIterable {
    case source, destination
    var title: String { self == .source ? "Source" : "Destination" }
}

struct SelectionRequest: Equatable, Sendable {
    let id = UUID()
    let generation: UUID
    let role: SelectionRole
}

enum SessionState: Equatable {
    case empty, selecting, ready, creating, completed, needsAttention
}

enum PreflightState: Equatable, Sendable {
    case none, checking, ready(URL), conflict(URL, isSameLink: Bool), invalid(String, SelectionRole)

    var canCreate: Bool { if case .ready = self { true } else { false } }
    var conflictURL: URL? { if case .conflict(let url, _) = self { url } else { nil } }
}

/// A selection owns one lease. A filesystem job retains its leases until its syscall finishes,
/// even if the droplet is disabled while the job is in flight.
final class SecurityScopeLease: @unchecked Sendable {
    let url: URL
    private let accessed: Bool
    init(url: URL) {
        self.url = url
        accessed = url.startAccessingSecurityScopedResource()
    }
    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
}

enum FileIO {
    private static let queue = DispatchQueue(label: "app.getdroppy.symlinker.files", qos: .userInitiated, attributes: .concurrent)
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var canceled = false
        func cancel() { lock.lock(); canceled = true; lock.unlock() }
        var isCanceled: Bool { lock.lock(); defer { lock.unlock() }; return canceled }
    }

    static func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !cancellation.isCanceled else { continuation.resume(throwing: CancellationError()); return }
                    continuation.resume(with: Result { try work() })
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

/// Decode Finder's file URL representations without accepting web URLs or remote file hosts.
enum FileDrop {
    static func url(from item: NSSecureCoding?) -> URL? {
        let candidate: URL?
        if let url = item as? URL { candidate = url }
        else if let data = item as? Data {
            candidate = URL(dataRepresentation: data, relativeTo: nil)
                ?? String(data: data, encoding: .utf8).flatMap(url(from:))
        } else if let string = item as? String { candidate = url(from: string) }
        else { candidate = nil }
        return candidate.flatMap(localURL)
    }

    static func localURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path(percentEncoded: false).contains("\0"),
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
        // Keep the original URL's sandbox grant and chosen alias/symlink identity.
        return url
    }

    private static func url(from string: String) -> URL? {
        if string.hasPrefix("/") { return URL(fileURLWithPath: string) }
        return URL(string: string)
    }

    @MainActor static func load(_ provider: NSItemProvider) async -> URL? {
        let request = ProviderLoad()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.install(continuation) else { return }
                let progress: Progress
                if provider.canLoadObject(ofClass: NSURL.self) {
                    progress = provider.loadObject(ofClass: NSURL.self) { item, error in
                        request.finish(error == nil ? (item as? URL).flatMap(localURL) : nil)
                    }
                } else {
                    progress = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                        request.finish(error == nil ? url(from: data as NSData?) : nil)
                    }
                }
                request.setProgress(progress)
            }
        } onCancel: { request.finish(nil) }
    }
}

/// Item providers are allowed to finish late, twice, or not at all. Resolve once, with a deadline,
/// and resume immediately on cancellation rather than keeping a hidden editor's task suspended.
final class ProviderLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL?, Never>?
    private var progress: Progress?
    private var timeout: DispatchWorkItem?
    private var finished = false
    private let deadline: TimeInterval
    init(timeout: TimeInterval = 10) { deadline = timeout }

    func install(_ continuation: CheckedContinuation<URL?, Never>) -> Bool {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(returning: nil); return false }
        self.continuation = continuation
        let timeout = DispatchWorkItem { [weak self] in self?.finish(nil) }
        self.timeout = timeout
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline, execute: timeout)
        return true
    }
    func setProgress(_ progress: Progress) {
        lock.lock()
        if finished { lock.unlock(); progress.cancel(); return }
        self.progress = progress
        lock.unlock()
    }
    func finish(_ url: URL?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation, progress = progress, timeout = timeout
        self.continuation = nil; self.progress = nil; self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        progress?.cancel()
        continuation?.resume(returning: url)
    }
}

enum LinkError: LocalizedError {
    case destinationMustBeFolder, nameTaken, missingSource, unavailableDestination, invalidDrop, multipleItems
    var errorDescription: String? {
        switch self {
        case .destinationMustBeFolder: "Choose a folder for the destination. Your previous selection is unchanged."
        case .nameTaken: "An item with this name already exists. Choose another folder."
        case .missingSource: "The source is unavailable. Reconnect its drive or choose it again."
        case .unavailableDestination: "The destination is unavailable. Reconnect its drive or choose another folder."
        case .invalidDrop: "Drop a local file or folder from Finder. Your previous selection is unchanged."
        case .multipleItems: "Drop one item at a time. Your previous selection is unchanged."
        }
    }
}

enum SymbolicLink {
    static func validateSelection(_ url: URL, role: SelectionRole) throws {
        guard FileDrop.localURL(url) != nil else { throw LinkError.invalidDrop }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
            throw role == .source ? LinkError.missingSource : LinkError.unavailableDestination
        }
        if role == .destination && !directory.boolValue { throw LinkError.destinationMustBeFolder }
    }

    static func preflight(source: URL, destination: URL) -> PreflightState {
        do { try validateSelection(source, role: .source) }
        catch { return .invalid(error.localizedDescription, .source) }
        do { try validateSelection(destination, role: .destination) }
        catch { return .invalid(error.localizedDescription, .destination) }
        let link = destination.appendingPathComponent(source.lastPathComponent)
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        if FileManager.default.fileExists(atPath: link.path) || target != nil {
            let resolvedTarget = target.map { URL(fileURLWithPath: $0, relativeTo: destination).standardizedFileURL }
            return .conflict(link, isSameLink: resolvedTarget == source.standardizedFileURL)
        }
        return .ready(link)
    }

    static func create(source: URL, destination: URL) throws -> URL {
        try validateSelection(source, role: .source)
        try validateSelection(destination, role: .destination)
        let link = destination.appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: link.path),
              (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil else { throw LinkError.nameTaken }
        // This syscall also refuses an item that appears AFTER the preflight. Never remove or replace it.
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        return link
    }
}
