import Foundation
import Testing
@testable import CodexMeter

struct AppUpdateCheckerTests {
    private var validInfo: [String: Any] {
        ["SUFeedURL": "https://raw.githubusercontent.com/niujt/CodexMeter/main/updates/macos/appcast.xml",
         // Synthetic public bytes only; never used to sign or publish an update.
         "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
         "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
         "SUSignedFeedFailureExpirationInterval": 0]
    }

    @Test func acceptsConfiguredSignedMacOSFeed() {
        #expect(AppUpdateConfiguration(info: validInfo).problem == nil)
    }

    @Test func missingConfigurationFailsClosed() {
        #expect(AppUpdateConfiguration(info: [:]).problem != nil)
    }

    @Test func rejectsWrongOrInsecureFeeds() {
        for feed in ["", "$(CODEX_HEALTH_UPDATE_FEED_URL)",
                     "http://raw.githubusercontent.com/niujt/CodexMeter/main/updates/macos/appcast.xml",
                     "https://evil.example/niujt/CodexMeter/main/updates/macos/appcast.xml",
                     "https://raw.githubusercontent.com/other/CodexMeter/main/updates/macos/appcast.xml",
                     "https://raw.githubusercontent.com/niujt/CodexMeter/main/updates/windows/appcast.xml",
                     "https://raw.githubusercontent.com/niujt/CodexMeter/main/updates/macos/appcast.xml?token=x",
                     "https://user@raw.githubusercontent.com/niujt/CodexMeter/main/updates/macos/appcast.xml",
                     "https://raw.githubusercontent.com:443/niujt/CodexMeter/main/updates/macos/appcast.xml"] {
            var info = validInfo
            info["SUFeedURL"] = feed
            #expect(AppUpdateConfiguration(info: info).problem != nil)
        }
    }

    @Test func rejectsMissingMalformedAndPlaceholderKeys() {
        for key in ["", "$(CODEX_HEALTH_UPDATE_PUBLIC_KEY)", "REPLACE_ME",
                    Data(repeating: 0, count: 32).base64EncodedString(),
                    Data(repeating: 1, count: 31).base64EncodedString()] {
            var info = validInfo
            info["SUPublicEDKey"] = key
            #expect(AppUpdateConfiguration(info: info).problem != nil)
        }
    }

    @Test func refusesToDisableEitherSignatureCheck() {
        for setting in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            var info = validInfo
            info[setting] = false
            #expect(AppUpdateConfiguration(info: info).problem != nil)
        }
    }
    @Test func refusesSignatureFailureExpirationFallback() {
        for interval in [1, 1_728_000] {
            var info = validInfo
            info["SUSignedFeedFailureExpirationInterval"] = interval
            #expect(AppUpdateConfiguration(info: info).problem != nil)
        }
        var info = validInfo
        info.removeValue(forKey: "SUSignedFeedFailureExpirationInterval")
        #expect(AppUpdateConfiguration(info: info).problem != nil)
    }

}
