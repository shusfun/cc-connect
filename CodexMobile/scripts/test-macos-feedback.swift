import AppKit
import Foundation

@main
struct FeedbackTests {
    @MainActor static func main() {
        let now = Date()
        precondition(ActivationPolicy.deadline(expiresAt: 400000, serverTime: 100000, now: now).timeIntervalSince(now) == 300)
        precondition(ActivationPolicy.deadline(expiresAt: 1, serverTime: 2, now: now) == now)
        precondition(ActivationPolicy.delay(retryAfter: 30, remaining: 15) == 15)
        precondition(ActivationPolicy.delay(retryAfter: 1, remaining: 300) == 3)
        enum Failure: Error { case storage }
        var published = false
        do { try ActivationPolicy.commit(save: { throw Failure.storage }, publish: { published = true }); preconditionFailure("expected storage failure") } catch {}
        precondition(!published)
        var saved = false
        try! ActivationPolicy.commit(save: { saved = true }, publish: { precondition(saved); published = true })
        precondition(published)
        print("activation_deadline_retry_and_commit_passed")
        guard CommandLine.arguments.contains("--window") else { return }
        let app = NSApplication.shared
        let coordinator = WindowCoordinator()
        var created = 0, events: [String] = []
        coordinator.configure(makeContent: {
            created += 1
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 680))
            let label = NSTextField(labelWithString: "Remodex Dock 自动测试；不读取账号、不启动 Bridge，测试后自动关闭。")
            label.frame = NSRect(x: 40, y: 300, width: 860, height: 80); view.addSubview(label); return view
        }, log: { events.append($0) })
        Task { @MainActor in
            coordinator.launch(atLogin: true, activated: true)
            precondition(app.activationPolicy() == .accessory && coordinator.window == nil)
            coordinator.show(); coordinator.window?.title = "Remodex Dock 自动测试"
            try? await Task.sleep(for: .milliseconds(300))
            precondition(app.activationPolicy() == .regular && coordinator.window?.isVisible == true)
            let window = coordinator.window!
            coordinator.show(); precondition(coordinator.window === window && created == 1)
            window.miniaturize(nil); try? await Task.sleep(for: .milliseconds(600))
            precondition(app.activationPolicy() == .regular)
            coordinator.show(); precondition(coordinator.window === window)
            window.close(); try? await Task.sleep(for: .milliseconds(200))
            precondition(app.activationPolicy() == .accessory)
            coordinator.show(); window.close(); coordinator.show()
            try? await Task.sleep(for: .milliseconds(200))
            precondition(app.activationPolicy() == .regular && coordinator.window === window && created == 1)
            window.close(); try? await Task.sleep(for: .milliseconds(200))
            precondition(app.activationPolicy() == .accessory)
            precondition(events.contains("window_closed") && events.contains("dock_shown") && events.contains("dock_hidden"))
            print("real_appkit_window_dock_lifecycle_passed")
            app.stop(nil)
            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
        }
        app.run()
    }
}
