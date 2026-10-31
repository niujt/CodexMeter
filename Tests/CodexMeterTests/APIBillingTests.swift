import Foundation
import Testing
import AppKit
import SwiftUI
@testable import CodexMeter

struct APIBillingTests {
    private let now = Date(timeIntervalSince1970: 1_793_404_800) // 2026-10-31 UTC
    private static let key = "sk-synthetic-billing-test-000000"
    private static let noLimit = Data(#"{"error":{"code":"not_found","message":"No organization spend limit is configured."}}"#.utf8)

    private static func page(_ results: String, more: Bool = false, next: String? = nil) -> Data {
        Data("{\"data\":[{\"results\":[\(results)]}],\"has_more\":\(more),\"next_page\":\(next.map { "\"\($0)\"" } ?? "null")}".utf8)
    }
    private static func cost(_ amount: String = "1.25", currency: String = "usd") -> String {
        "{\"amount\":{\"value\":\(amount),\"currency\":\"\(currency)\"}}"
    }
    private static func usage(_ input: Int64 = 100, output: Int64 = 20, cached: Int64 = 40) -> String {
        "{\"input_tokens\":\(input),\"output_tokens\":\(output),\"input_cached_tokens\":\(cached),\"num_model_requests\":2}"
    }
    private static func limit(_ cents: Int64 = 10_000) -> Data {
        Data("{\"threshold_amount\":\(cents),\"currency\":\"USD\",\"interval\":\"month\",\"enforcement\":{\"status\":\"enforcing\"}}".utf8)
    }

    private actor Pages {
        var requests: [URLRequest] = []
        func send(_ request: URLRequest) -> (Data, Int) {
            requests.append(request)
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let cursor = components.queryItems?.first { $0.name == "page" }?.value
            switch request.url!.path {
            case "/v1/organization/costs":
                return (Self.pageCost(cursor), 200)
            case "/v1/organization/usage/completions":
                return (APIBillingTests.page(APIBillingTests.usage(), more: cursor == nil, next: cursor == nil ? "next+page/2" : nil), 200)
            default: return (APIBillingTests.noLimit, 404)
            }
        }
        private static func pageCost(_ cursor: String?) -> Data {
            APIBillingTests.page(APIBillingTests.cost(cursor == nil ? "0.1" : "0.2"), more: cursor == nil, next: cursor == nil ? "next+page/2" : nil)
        }
    }

    @Test func paginatesCostsAndUsageWithoutRoundingOrDoubleCountingCachedInput() async throws {
        let pages = Pages()
        let client = OpenAIBillingClient(transport: { await pages.send($0) })
        let snapshot = try await client.load(key: Self.key, now: now)
        #expect(snapshot.costs.value?.usd == Decimal(string: "0.3"))
        #expect(snapshot.usage.value == APIUsageTotals(input: 200, output: 40, cachedInput: 80, requests: 4))
        #expect(snapshot.spendLimit.value == .notConfigured)
        #expect(snapshot.estimatedBudgetRemaining == nil)
        #expect(snapshot.warnings.isEmpty)
        let requests = await pages.requests
        #expect(requests.count == 5)
        for request in requests {
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "api.openai.com")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            if request.url?.path != "/v1/organization/spend_limit" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                #expect(query.first { $0.name == "start_time" }?.value == String(Int(snapshot.periodStart.timeIntervalSince1970)))
                #expect(query.first { $0.name == "end_time" }?.value == String(Int(APIBillingSnapshot.queryEnd(at: now).timeIntervalSince1970)))
            }
        }
        let paged = requests.filter { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "page", value: "next+page/2")) == true }
        #expect(paged.count == 2)
    }

    @Test(arguments: ["cycle", "missing-cursor", "second-page-failure"])
    func incompleteCostPagesNeverBecomePartialSuccessfulTotals(_ mode: String) async throws {
        let client = OpenAIBillingClient(transport: { request in
            if request.url!.path.hasSuffix("costs") {
                let isSecond = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "page" } == true
                if mode == "second-page-failure", isSecond { return (Data(), 500) }
                return (Self.page(Self.cost(), more: true, next: mode == "missing-cursor" ? nil : "same"), 200)
            }
            if request.url!.path.hasSuffix("spend_limit") { return (Self.limit(), 200) }
            return (Self.page(Self.usage()), 200)
        })
        let snapshot = try await client.load(key: Self.key, now: now)
        #expect(snapshot.costs.value == nil)
        #expect(snapshot.costs.error != nil)
        #expect(snapshot.usage.value?.input == 100)
        #expect(snapshot.estimatedBudgetRemaining == nil)
    }

    @Test(arguments: [401, 403, 302, 429, 500])
    func httpErrorsAreSafeAndDoNotReportZero(_ status: Int) async throws {
        let client = OpenAIBillingClient(transport: { _ in
            (Data("sensitive upstream body \(Self.key)".utf8), status)
        })
        let snapshot = try await client.load(key: Self.key, now: now)
        #expect(!snapshot.hasData)
        #expect(snapshot.costs.value == nil)
        #expect(snapshot.warnings.count == 3)
        #expect(!snapshot.warnings.joined().contains(Self.key))
        if status == 403 {
            #expect(snapshot.costs.error == .rejected(403))
            #expect(snapshot.spendLimit.error == .rejected(403))
        }
    }

    @Test func missingScopesAreDistinguishedFromOtherForbiddenResponses() async throws {
        let client = OpenAIBillingClient(transport: { request in
            let scope = request.url!.path.hasSuffix("spend_limit") ? "api.management.read" : "api.usage.read"
            return (Data("{\"error\":\"Insufficient permissions. Missing scopes: \(scope).\"}".utf8), 403)
        })
        let snapshot = try await client.load(key: Self.key, now: now)
        #expect(snapshot.costs.error == .permission("api.usage.read"))
        #expect(snapshot.spendLimit.error == .permission("api.management.read"))
    }

    @Test func onlyKnownUnconfiguredLimitResponseMeansNoLimit() async throws {
        let client = OpenAIBillingClient(transport: { request in
            if request.url!.path.hasSuffix("spend_limit") {
                return (Data(#"{"error":{"code":"not_found","message":"Unknown route"}}"#.utf8), 404)
            }
            return (Self.page(""), 200)
        })
        let snapshot = try await client.load(key: Self.key, now: now)
        #expect(snapshot.spendLimit.value == nil)
        #expect(snapshot.spendLimit.error == .rejected(404))
        #expect(snapshot.costs.value?.usd == 0)
    }

    @Test func budgetUsesCentsAndCostsButIsAbsentForOtherCurrencies() async throws {
        for currency in ["usd", "eur"] {
            let client = OpenAIBillingClient(transport: { request in
                if request.url!.path.hasSuffix("spend_limit") { return (Self.limit(12345), 200) }
                if request.url!.path.hasSuffix("costs") { return (Self.page(Self.cost("8.094851825", currency: currency)), 200) }
                return (Self.page(Self.usage()), 200)
            })
            let snapshot = try await client.load(key: Self.key, now: now)
            #expect(snapshot.spendLimit.value == .configured(amount: Decimal(string: "123.45")!, enforcing: true))
            if currency == "usd" {
                #expect(snapshot.estimatedBudgetRemaining == Decimal(string: "115.355148175"))
            } else { #expect(snapshot.estimatedBudgetRemaining == nil) }
        }
    }

    @Test(arguments: ["malformed", "negative-tokens", "cached-exceeds-input", "overflow", "negative-limit"])
    func invalidDataFailsOnlyTheAffectedSection(_ mode: String) async throws {
        let client = OpenAIBillingClient(transport: { request in
            if request.url!.path.hasSuffix("spend_limit") { return (Self.limit(mode == "negative-limit" ? -1 : 10000), 200) }
            if request.url!.path.hasSuffix("costs") { return (mode == "malformed" ? Data("{}".utf8) : Self.page(Self.cost()), 200) }
            let rows: String
            switch mode {
            case "negative-tokens": rows = Self.usage(-1, cached: 0)
            case "cached-exceeds-input": rows = Self.usage(10, cached: 11)
            case "overflow": rows = Self.usage(.max, cached: 0) + "," + Self.usage(1, cached: 0)
            default: rows = Self.usage()
            }
            return (Self.page(rows), 200)
        })
        let snapshot = try await client.load(key: Self.key, now: now)
        #expect(snapshot.warnings.count == 1)
        #expect(snapshot.hasData)
    }

    @Test func keyImportRejectsAmbiguousAndMalformedFiles() throws {
        #expect(try APIKeychain.extract(from: Self.key + "\n") == Self.key)
        #expect(try APIKeychain.extract(from: "OPENAI_ADMIN_KEY=\"\(Self.key)\"") == Self.key)
        for text in ["", "sk-short", Self.key + "\n" + Self.key, "Bearer\r\ninjected:value"] {
            #expect(throws: APIBillingError.self) { try APIKeychain.extract(from: text) }
        }
    }

    @Test func monthBoundaryUsesUTCInsteadOfLocalCalendar() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-31T23:30:00Z"))
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        #expect(APIBillingSnapshot.monthStart(at: date) == expected)
        #expect(APIBillingSnapshot.queryEnd(at: date) == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
    }

    @MainActor private final class CredentialBox { var key: String? = APIBillingTests.key }

    @MainActor @Test func storeThrottlesIncidentalRefreshAndClearsReplacedCredentialData() async {
        let box = CredentialBox()
        let pages = Pages()
        let store = APIBillingStore(client: OpenAIBillingClient(transport: { await pages.send($0) }),
                                    readKey: { box.key }, writeKey: { box.key = $0 })
        await store.refresh(now: now)
        #expect(store.snapshot != nil)
        await store.refresh(now: now.addingTimeInterval(60))
        #expect(await pages.requests.count == 5)
        await store.refresh(force: true, now: now.addingTimeInterval(61))
        #expect(await pages.requests.count == 10)
        #expect(store.saveCredential("sk-synthetic-replacement-000000"))
        #expect(store.snapshot == nil)
        await store.refresh(now: now.addingTimeInterval(62))
        #expect(await pages.requests.count == 15)
        box.key = nil
        store.checkCredential()
        #expect(!store.hasCredential)
        #expect(store.snapshot == nil)
    }

    @MainActor @Test func failedKeychainSavePreservesExistingCredentialAndData() async {
        let store = APIBillingStore(client: OpenAIBillingClient(transport: { request in
            request.url!.path.hasSuffix("spend_limit") ? (Self.noLimit, 404) : (Self.page(""), 200)
        }), readKey: { Self.key }, writeKey: { _ in throw APIBillingError.keychain(-1) })
        await store.refresh(now: now)
        #expect(!store.saveCredential("sk-synthetic-replacement-000000"))
        #expect(store.snapshot?.costs.value?.usd == 0)
        #expect(store.hasCredential)
        #expect(store.errorMessage?.contains("钥匙串") == true)
    }

    private actor DelayedResponse {
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
            if request.url!.path.hasSuffix("spend_limit") { return (APIBillingTests.noLimit, 404) }
            if request.url!.path.hasSuffix("costs") {
                let old = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(APIBillingTests.key)"
                return (APIBillingTests.page(APIBillingTests.cost(old ? "999" : "2")), 200)
            }
            return (APIBillingTests.page(APIBillingTests.usage()), 200)
        }
    }

    @MainActor @Test func replacingCredentialDuringRequestRejectsOldAccountResult() async {
        let box = CredentialBox()
        let delayed = DelayedResponse()
        let store = APIBillingStore(client: OpenAIBillingClient(transport: { await delayed.send($0) }),
                                    readKey: { box.key }, writeKey: { box.key = $0 })
        let old = Task { await store.refresh(now: now) }
        await delayed.waitUntilStarted()
        #expect(store.isRefreshing)
        #expect(store.saveCredential("sk-synthetic-replacement-000000"))
        await store.refresh(now: now)
        #expect(store.snapshot?.costs.value?.usd == 2)
        await delayed.release()
        await old.value
        #expect(store.snapshot?.costs.value?.usd == 2)
        #expect(!store.isRefreshing)
    }

    @MainActor @Test func rendersAPIPageAndSettingsWithSyntheticCredentials() async throws {
        _ = NSApplication.shared
        let root = TestFixtureDirectory.root.appendingPathComponent("api-billing-previews")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for state in ["configured", "no-limit", "denied", "unconfigured"] {
            let store = APIBillingStore(client: OpenAIBillingClient(transport: { request in
                if state == "denied" { return (Data(), 403) }
                if request.url!.path.hasSuffix("spend_limit") {
                    return state == "no-limit" ? (Self.noLimit, 404) : (Self.limit(), 200)
                }
                if request.url!.path.hasSuffix("costs") { return (Self.page(Self.cost("8.12")), 200) }
                return (Self.page(Self.usage(29_257_495, output: 63_885, cached: 25_000_000)), 200)
            }), readKey: { state == "unconfigured" ? nil : Self.key }, writeKey: { _ in })
            await store.refresh()
            for dark in [false, true] {
                let view = ScrollView { APIBillingView(billing: store) }
                    .frame(width: 860, height: 650)
                    .background(DashboardPalette.canvas)
                    .foregroundStyle(DashboardPalette.ink).tint(DashboardPalette.ink)
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                try await render(view, size: .init(width: 860, height: 650), dark: dark,
                                 to: root.appendingPathComponent("\(state)-\(dark ? "dark" : "light").png"))
            }
        }
        let settingsStore = APIBillingStore(readKey: { nil }, writeKey: { _ in })
        let settings = APIBillingSettingsView(billing: settingsStore).frame(width: 520, height: 440)
            .environment(\.locale, Locale(identifier: "zh_CN"))
        try await render(settings, size: .init(width: 520, height: 440), dark: false,
                         to: root.appendingPathComponent("settings-light.png"))
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
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    }
}
