import Foundation
import Observation
import CryptoKit

@MainActor @Observable
final class APIBillingStore {
    static let shared = APIBillingStore()
    private(set) var snapshot: APIBillingSnapshot?
    private(set) var isRefreshing = false
    private(set) var hasCredential = false
    private(set) var errorMessage: String?
    private(set) var credentialRevision = UUID()
    @ObservationIgnored private let client: OpenAIBillingClient
    @ObservationIgnored private let readKey: () throws -> String?
    @ObservationIgnored private let writeKey: (String) throws -> Void
    @ObservationIgnored private var task: Task<APIBillingSnapshot, Error>?
    private var generation = UUID()
    private var fingerprint: String?
    private var lastAttempt: Date?

    init(client: OpenAIBillingClient = OpenAIBillingClient(),
         readKey: @escaping () throws -> String? = { try APIKeychain().read() },
         writeKey: @escaping (String) throws -> Void = { try APIKeychain().save($0) }) {
        self.client = client
        self.readKey = readKey
        self.writeKey = writeKey
    }

    func checkCredential() {
        do { _ = try credential() }
        catch { invalidate(); hasCredential = false; fingerprint = nil; errorMessage = Self.safeMessage(error) }
    }

    @discardableResult
    func saveCredential(_ text: String) -> Bool {
        do {
            let key = try APIKeychain.extract(from: text)
            try writeKey(key)
            invalidate()
            credentialRevision = UUID()
            fingerprint = Self.digest(key)
            hasCredential = true
            errorMessage = nil
            return true
        } catch { errorMessage = Self.safeMessage(error); return false }
    }

    func refresh(force: Bool = false, now: Date = .now) async {
        let key: String
        do {
            guard let credential = try credential() else { return }
            key = credential
        } catch { invalidate(); hasCredential = false; fingerprint = nil; errorMessage = Self.safeMessage(error); return }
        guard !isRefreshing else { return }
        if !force, let lastAttempt, now >= lastAttempt, now.timeIntervalSince(lastAttempt) < 300,
           snapshot?.periodStart == APIBillingSnapshot.monthStart(at: now) { return }
        let ticket = generation
        isRefreshing = true
        lastAttempt = now
        errorMessage = nil
        let client = client
        let pending = Task { try await client.load(key: key, now: now) }
        task = pending
        do {
            let loaded = try await pending.value
            guard ticket == generation else { return }
            snapshot = loaded
        } catch is CancellationError {
            // Replacing a credential invalidates the old request and all old account data.
        } catch {
            guard ticket == generation else { return }
            errorMessage = Self.safeMessage(error)
        }
        guard ticket == generation else { return }
        isRefreshing = false
        task = nil
    }

    private func credential() throws -> String? {
        let key = try readKey()
        let identity = key.map(Self.digest)
        if fingerprint != identity { invalidate(); fingerprint = identity }
        hasCredential = key != nil
        return key
    }

    private func invalidate() {
        task?.cancel()
        task = nil
        generation = UUID()
        snapshot = nil
        lastAttempt = nil
        isRefreshing = false
        errorMessage = nil
    }

    private static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeMessage(_ error: Error) -> String {
        (error as? APIBillingError)?.localizedDescription ?? APIBillingError.unavailable.localizedDescription
    }
}
