import Foundation
import AppKit
import SwiftUI
import Testing
@testable import CodexMeter

struct DeepSeekBalanceTests {
    private static let key = "sk-synthetic-deepseek-test-000000"
    private let now = Date(timeIntervalSince1970: 1_793_424_000)

    private static func payload(available: Bool = true, rows: String? = nil) -> Data {
        Data("{\"is_available\":\(available),\"balance_infos\":[\(rows ?? row())]}".utf8)
    }
    private static func row(currency: String = "CNY", total: String = "110.00", granted: String = "10.00", topped: String = "100.00") -> String {
        "{\"currency\":\"\(currency)\",\"total_balance\":\"\(total)\",\"granted_balance\":\"\(granted)\",\"topped_up_balance\":\"\(topped)\"}"
    }

    @Test func decodesOfficialStringBalancesExactlyAndKeepsCurrenciesSeparate() throws {
        let data = Self.payload(rows: Self.row() + "," + Self.row(currency: "USD", total: "0.12345678", granted: "0.00000001", topped: "0.12345677"))
        let result = try DeepSeekBalanceClient.decode(data, checkedAt: now)
        #expect(result.isAvailable)
        #expect(result.checkedAt == now)
        #expect(result.balances.count == 2)
        #expect(result.balances[0] == DeepSeekBalance(currency: "CNY", total: 110, granted: 10, toppedUp: 100))
        #expect(result.balances[1].total == Decimal(string: "0.12345678"))
        #expect(result.balances[1].toppedUp == Decimal(string: "0.12345677"))
    }

    @Test func unavailableAndEmptyBalancesDoNotInventZeroOrDiscardServerState() throws {
        let empty = try DeepSeekBalanceClient.decode(Self.payload(available: false, rows: ""), checkedAt: now)
        #expect(!empty.isAvailable)
        #expect(empty.balances.isEmpty)
        let nonzero = try DeepSeekBalanceClient.decode(Self.payload(available: false), checkedAt: now)
        #expect(!nonzero.isAvailable)
        #expect(nonzero.balances.first?.total == 110)
        let negative = try DeepSeekBalanceClient.decode(Self.payload(available: false, rows: Self.row(total: "-0.05", granted: "0", topped: "-0.05")), checkedAt: now)
        #expect(negative.balances.first?.total == Decimal(string: "-0.05"))
    }

    @Test(arguments: ["NaN", "Infinity", "", "12abc", "1,000.00", "1e2", " 1.2", "1.2 ", "1.\n", "123456789012345678901234567890123456789"])
    func rejectsInvalidAmounts(_ amount: String) {
        #expect(throws: DeepSeekBalanceError.self) {
            try DeepSeekBalanceClient.decode(Self.payload(rows: Self.row(total: amount)), checkedAt: now)
        }
    }

    @Test func rejectsMissingFieldsUnknownCurrencyDuplicateCurrencyAndNumericAmounts() {
        let malformed = [Data("{}".utf8), Self.payload(rows: Self.row(currency: "EUR")),
                         Self.payload(rows: Self.row() + "," + Self.row()),
                         Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":1,"granted_balance":"0","topped_up_balance":"1"}]}"#.utf8)]
        for data in malformed {
            #expect(throws: DeepSeekBalanceError.self) { try DeepSeekBalanceClient.decode(data, checkedAt: now) }
        }
    }

    @Test func requestUsesOnlyOfficialReadOnlyBalanceEndpoint() async throws {
        let client = DeepSeekBalanceClient(transport: { request in
            #expect(request.url?.absoluteString == "https://api.deepseek.com/user/balance")
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return (Self.payload(), 200)
        })
        let result = try await client.load(key: Self.key, now: now)
        #expect(result.balances.first?.total == 110)
    }

    @Test(arguments: [401, 402, 403, 429, 500, 302])
    func rejectedResponsesNeverExposeUpstreamSecretsOrReturnZero(_ status: Int) async {
        let client = DeepSeekBalanceClient(transport: { _ in (Data("upstream secret: \(Self.key)".utf8), status) })
        do {
            _ = try await client.load(key: Self.key, now: now)
            Issue.record("Rejected response was accepted")
        } catch let error as DeepSeekBalanceError {
            #expect(error == (status == 401 ? .unauthorized : .rejected(status)))
            #expect(!error.localizedDescription.contains(Self.key))
        } catch { Issue.record("Unexpected error type") }
    }

    @Test func transportErrorsAndInvalidKeysAreSanitized() async {
        let client = DeepSeekBalanceClient(transport: { _ in
            throw NSError(domain: "secret: \(Self.key)", code: 1)
        })
        await #expect(throws: DeepSeekBalanceError.invalidKey) { try await client.load(key: "bad") }
        await #expect(throws: DeepSeekBalanceError.unavailable) { try await client.load(key: Self.key) }
    }

    @Test func keychainNamespacesAreSeparateAndOpenAIIdentityIsPreserved() {
        let openAI = APIKeychain()
        let deepSeek = APIKeychain(provider: .deepSeek)
        #expect(openAI.service == "com.codexmeter.CodexMeter.openai-billing")
        #expect(openAI.account == "organization-admin-key")
        #expect(deepSeek.service != openAI.service)
        #expect(deepSeek.account != openAI.account)
    }

    private actor Server {
        var calls = 0
        var failed = false
        func fail() { failed = true }
        func send(_ request: URLRequest) throws -> (Data, Int) {
            calls += 1
            if failed { throw URLError(.notConnectedToInternet) }
            return (DeepSeekBalanceTests.payload(), 200)
        }
    }
    @MainActor private final class KeyBox { var value: String? = DeepSeekBalanceTests.key }

    @MainActor @Test func storeCachesManualRefreshBypassesAndFailuresPreserveDatedSnapshot() async {
        let server = Server()
        let box = KeyBox()
        let store = DeepSeekBalanceStore(client: DeepSeekBalanceClient(transport: { try await server.send($0) }),
                                        readKey: { box.value }, writeKey: { box.value = $0 })
        await store.refresh(now: now)
        await store.refresh(now: now.addingTimeInterval(60))
        #expect(await server.calls == 1)
        await store.refresh(force: true, now: now.addingTimeInterval(61))
        #expect(await server.calls == 2)
        await server.fail()
        await store.refresh(force: true, now: now.addingTimeInterval(62))
        #expect(store.snapshot?.checkedAt == now.addingTimeInterval(61))
        #expect(store.snapshot?.balances.first?.total == 110)
        #expect(store.errorMessage != nil)
        #expect(store.saveCredential("sk-synthetic-new-deepseek-0000"))
        #expect(store.snapshot == nil)
        #expect(store.errorMessage == nil)
        box.value = nil
        store.checkCredential()
        #expect(!store.hasCredential)
        await store.refresh(now: now.addingTimeInterval(63))
        #expect(await server.calls == 3)
    }

    @MainActor @Test func failedWritesPreservePreviousDataAndCredentialErrorsClearIt() async {
        let box = KeyBox()
        let store = DeepSeekBalanceStore(client: DeepSeekBalanceClient(transport: { _ in (Self.payload(), 200) }),
                                        readKey: {
                                            if box.value == nil { throw APIBillingError.keychain(-1) }
                                            return box.value
                                        }, writeKey: { _ in throw APIBillingError.keychain(-1) })
        await store.refresh(now: now)
        #expect(!store.saveCredential("sk-synthetic-new-deepseek-0000"))
        #expect(store.snapshot != nil)
        #expect(store.hasCredential)
        #expect(!store.saveCredential("invalid"))
        #expect(store.errorMessage == DeepSeekBalanceError.invalidKey.localizedDescription)
        box.value = nil
        store.checkCredential()
        #expect(store.snapshot == nil)
        #expect(!store.hasCredential)
        #expect(store.errorMessage == DeepSeekBalanceError.keychain(-1).localizedDescription)
    }

    private actor DelayedServer {
        var continuation: CheckedContinuation<Void, Never>?
        var waiter: CheckedContinuation<Void, Never>?
        var started = false
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
        func send(_ request: URLRequest) async -> (Data, Int) {
            if !started {
                started = true
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    waiter?.resume(); waiter = nil
                }
            }
            let old = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(DeepSeekBalanceTests.key)"
            return (DeepSeekBalanceTests.payload(rows: DeepSeekBalanceTests.row(total: old ? "999" : "2")), 200)
        }
    }

    @MainActor @Test func replacingKeyWhileLoadingDiscardsOldAccountResult() async {
        let box = KeyBox()
        let server = DelayedServer()
        let store = DeepSeekBalanceStore(client: DeepSeekBalanceClient(transport: { await server.send($0) }),
                                        readKey: { box.value }, writeKey: { box.value = $0 })
        let old = Task { await store.refresh(now: now) }
        await server.waitUntilStarted()
        #expect(store.saveCredential("sk-synthetic-new-deepseek-0000"))
        await store.refresh(now: now)
        #expect(store.snapshot?.balances.first?.total == 2)
        await server.release()
        await old.value
        #expect(store.snapshot?.balances.first?.total == 2)
        #expect(!store.isRefreshing)
    }

    @MainActor @Test func rendersBalanceStatesAndSettingsWithSyntheticData() async throws {
        _ = NSApplication.shared
        let root = TestFixtureDirectory.root.appendingPathComponent("deepseek-previews")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for state in ["balance", "multi-currency", "no-funds", "failed", "unconfigured"] {
            let server = Server()
            let store = DeepSeekBalanceStore(client: DeepSeekBalanceClient(transport: { request in
                if state == "failed" { return try await server.send(request) }
                if state == "no-funds" { return (Self.payload(available: false, rows: Self.row(total: "0.00", granted: "0.00", topped: "0.00")), 200) }
                let extra = state == "multi-currency" ? "," + Self.row(currency: "USD", total: "12.50", granted: "2.50", topped: "10.00") : ""
                return (Self.payload(rows: Self.row() + extra), 200)
            }), readKey: { state == "unconfigured" ? nil : Self.key }, writeKey: { _ in })
            await store.refresh()
            if state == "failed" { await server.fail(); await store.refresh(force: true) }
            for dark in [false, true] {
                let view = ScrollView { DeepSeekBalanceView(balance: store) }
                    .frame(width: 860, height: 650).background(DashboardPalette.canvas)
                    .foregroundStyle(DashboardPalette.ink).tint(DashboardPalette.ink)
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                try await render(view, size: .init(width: 860, height: 650), dark: dark,
                                 to: root.appendingPathComponent("\(state)-\(dark ? "dark" : "light").png"))
            }
        }
        for dark in [false, true] {
            let store = DeepSeekBalanceStore(readKey: { nil }, writeKey: { _ in })
            let view = DeepSeekSettingsView(balance: store).frame(width: 520, height: 440)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .environment(\.colorScheme, dark ? .dark : .light)
            try await render(view, size: .init(width: 520, height: 440), dark: dark,
                             to: root.appendingPathComponent("settings-\(dark ? "dark" : "light").png"))
        }
        let defaults = try #require(UserDefaults(suiteName: "CodexMeterTests.DeepSeekSettings." + UUID().uuidString))
        defaults.set("deepseek", forKey: APISettingsView.providerKey)
        let settings = APISettingsView(openAI: APIBillingStore(readKey: { nil }, writeKey: { _ in }),
                                       deepSeek: DeepSeekBalanceStore(readKey: { nil }, writeKey: { _ in }))
            .defaultAppStorage(defaults)
            .frame(width: 520, height: 440)
            .background(DashboardPalette.canvas)
            .foregroundStyle(DashboardPalette.ink).tint(DashboardPalette.ink)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.colorScheme, .light)
        try await render(settings, size: .init(width: 520, height: 440), dark: false,
                         to: root.appendingPathComponent("provider-selector-light.png"))
    }

    @MainActor private func render(_ view: some View, size: NSSize, dark: Bool, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        host.setFrameSize(size)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    }
}
