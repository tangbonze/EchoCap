import Testing
import Foundation
import Combine
@testable import EchoCapCore

@Suite("设置变更通知")
struct AppSettingsObservationTests {

    private func makeSettings() -> AppSettings {
        let name = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AppSettings(defaults: defaults)
    }

    @Test("改设置会发出变更通知")
    func changesNotify() {
        let settings = makeSettings()
        var notifications = 0
        let token = settings.objectWillChange.sink { notifications += 1 }

        settings.linesPerBox = 5
        settings.translationEngine = .cloud
        settings.showBothLanguages = true

        #expect(notifications == 3)
        token.cancel()
    }

    @Test("枚举与字符串设置同样会通知")
    func enumAndStringSettingsNotify() {
        let settings = makeSettings()
        var notifications = 0
        let token = settings.objectWillChange.sink { notifications += 1 }

        settings.translationTarget = "zh-Hans"
        settings.alignment = .center
        settings.summaryEngine = .cloud

        #expect(notifications == 3)
        token.cancel()
    }

    @Test("写入后立刻能读到新值")
    func valueIsVisibleImmediately() {
        let settings = makeSettings()
        settings.translationEngine = .cloud
        #expect(settings.translationEngine == .cloud)
        settings.cloudBaseURL = "https://api.example.com/v1"
        #expect(settings.cloudBaseURL == "https://api.example.com/v1")
    }
}
