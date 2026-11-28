import Foundation
import IOKit.pwr_mgt

@MainActor
final class PowerAssertionService: ObservableObject {
    @Published private(set) var isPreventingSleep: Bool = false

    private var assertionID: IOPMAssertionID = 0

    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    func sync(enabled: Bool, activeRunningCount: Int) {
        let shouldHold = enabled && activeRunningCount > 0
        if shouldHold && !isPreventingSleep {
            var newID: IOPMAssertionID = 0
            let reason = "Antigravity Pilot: Active agent session running" as CFString
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &newID
            )
            if result == kIOReturnSuccess {
                assertionID = newID
                isPreventingSleep = true
            }
        } else if !shouldHold && isPreventingSleep {
            releaseIfNeeded()
        }
    }

    func releaseIfNeeded() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        if isPreventingSleep {
            isPreventingSleep = false
        }
    }
}
