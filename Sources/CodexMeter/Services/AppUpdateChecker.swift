import Combine
import Foundation
#if !CODEX_HEALTH_PREVIEW
import Sparkle
#endif

/// Fail closed until the release owner supplies a real feed and its public signing key.
struct AppUpdateConfiguration {
    let feedURL: String
    let publicKey: String
    let requiresSignedFeed: Bool
    let verifiesBeforeExtraction: Bool
    let signatureFailureExpiration: Double?

    init(info: [String: Any]) {
        feedURL = info["SUFeedURL"] as? String ?? ""
        publicKey = info["SUPublicEDKey"] as? String ?? ""
        requiresSignedFeed = info["SURequireSignedFeed"] as? Bool ?? false
        verifiesBeforeExtraction = info["SUVerifyUpdateBeforeExtraction"] as? Bool ?? false
        signatureFailureExpiration = (info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.doubleValue
    }

    var problem: String? {
        guard let url = URL(string: feedURL), url.scheme == "https",
              url.host == "raw.githubusercontent.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/niujt/CodexMeter/main/updates/macos/appcast.xml" else {
            return "此构建尚未配置 macOS 更新源。"
        }
        guard let key = Data(base64Encoded: publicKey), key.count == 32,
              key.contains(where: { $0 != 0 }) else {
            return "此构建尚未配置更新签名公钥。"
        }
        guard requiresSignedFeed, verifiesBeforeExtraction, signatureFailureExpiration == 0 else {
            return "此构建缺少必要的更新签名校验配置。"
        }
        return nil
    }
}

/// One controller per app, retained across closing Settings and installing/relaunching.
/// Sparkle owns downloading, signature verification, cancellation, installation and relaunch.
@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var errorMessage: String?
    private var hasStarted = false
    #if !CODEX_HEALTH_PREVIEW
    private var controller: SPUStandardUpdaterController?
    #endif

    private init() {
        #if CODEX_HEALTH_PREVIEW
        errorMessage = "演示模式不连接更新服务。"
        #else
        let configuration = AppUpdateConfiguration(info: Bundle.main.infoDictionary ?? [:])
        errorMessage = configuration.problem
        canCheckForUpdates = errorMessage == nil
        #endif
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        #if !CODEX_HEALTH_PREVIEW
        if !hasStarted {
            let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                         updaterDelegate: nil, userDriverDelegate: nil)
            do {
                try controller.updater.start()
                self.controller = controller
                hasStarted = true
                controller.updater.publisher(for: \.canCheckForUpdates)
                    .assign(to: &$canCheckForUpdates)
            } catch {
                errorMessage = "更新服务无法启动：\(error.localizedDescription)"
                return
            }
        }
        errorMessage = nil
        // Repeated clicks focus Sparkle's existing update UI rather than create new downloads.
        controller?.checkForUpdates(nil)
        #endif
    }
}
