import SensoriumCore
import AppKit
import Observation

/// Optional one-click coffee cup in the menu bar: click = No Sleep on / off (no popover).
final class CoffeeItem: NSObject {
    static let shared = CoffeeItem()
    private var item: NSStatusItem?

    func start() { refresh() }

    /// Re-evaluates whenever the setting or the No Sleep state changes.
    private func refresh() {
        let hub = SensorHub.shared
        withObservationTracking {
            _ = hub.noSleep
            _ = Tweaks.shared.v.coffeeInMenuBar
        } onChange: {
            DispatchQueue.main.async { self.refresh() }
        }
        if Tweaks.shared.v.coffeeInMenuBar {
            if item == nil {
                item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item?.button?.target = self
                item?.button?.action = #selector(toggle)
            }
            let on = hub.noSleep
            let image = NSImage(systemSymbolName: on ? "cup.and.saucer.fill" : "cup.and.saucer",
                                accessibilityDescription: on ? "No Sleep on" : "No Sleep off")
            image?.isTemplate = true
            item?.button?.image = image
            item?.button?.toolTip = on ? "Keeping the Mac awake: click to allow sleep" : "Click to keep the Mac awake"
        } else if let i = item {
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    @objc private func toggle() { SensorHub.shared.setNoSleep(!SensorHub.shared.noSleep) }
}
