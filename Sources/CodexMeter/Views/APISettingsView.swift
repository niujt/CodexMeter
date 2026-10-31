import SwiftUI

@MainActor
struct APISettingsView: View {
    static let providerKey = "codexMeter.settings.apiProvider"
    var openAI = APIBillingStore.shared
    var deepSeek = DeepSeekBalanceStore.shared
    @AppStorage(APISettingsView.providerKey) private var provider = "openai"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("服务商").font(.callout)
                Spacer()
                Picker("服务商", selection: $provider) {
                    Text("OpenAI").tag("openai")
                    Text("DeepSeek").tag("deepseek")
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 180)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
            if provider == "deepseek" { DeepSeekSettingsView(balance: deepSeek) }
            else { APIBillingSettingsView(billing: openAI) }
        }
    }
}
