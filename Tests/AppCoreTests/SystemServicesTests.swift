import AppCore
import Foundation
import Testing

// The live notifier and login item, in a process that is not an app bundle (this one). Both must
// refuse politely: `UNUserNotificationCenter.current()` raises an exception without a bundle, and
// `SMAppService.mainApp` has nothing to register.
@Suite("System services outside an app bundle")
struct SystemServicesTests {
    @Test("the login item reports there is no bundle and refuses to register or unregister")
    func loginItem() {
        let item = MainAppLoginItem()
        #expect(item.status == .notInBundle)
        #expect(throws: LaunchAtLoginError.notInBundle) { try item.register() }
        #expect(throws: LaunchAtLoginError.notInBundle) { try item.unregister() }
        #expect(LaunchAtLoginError.notInBundle.description.contains("make app"))
    }

    @Test("the toggle is on for enabled and for approval pending, off otherwise")
    func toggle() {
        #expect(LaunchAtLoginStatus.enabled.isOn)
        #expect(LaunchAtLoginStatus.requiresApproval.isOn)
        #expect(!LaunchAtLoginStatus.notRegistered.isOn)
        #expect(!LaunchAtLoginStatus.notFound.isOn)
        #expect(!LaunchAtLoginStatus.notInBundle.isOn)
    }

    @Test("the notifier skips, with the reason, instead of touching the notification centre")
    func notifier() async {
        let outcome = await SystemNotifier().post(title: "Switchboard", body: "hello")
        #expect(outcome == .skipped("not running from an app bundle"))
    }
}
