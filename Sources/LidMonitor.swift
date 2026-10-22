import Foundation
import IOKit

// Unknown readings reset the baseline; starting while closed never sends an alert.
struct LidTransition {
  private var previous: Bool?
  mutating func update(closed: Bool?, enabled: Bool) -> Bool {
    guard enabled, let closed else {
      previous = nil
      return false
    }
    defer { previous = closed }
    return previous == false && closed
  }
}

final class LidMonitor {
  private var transition = LidTransition()
  func poll(enabled: Bool) -> Bool {
    guard enabled else { return transition.update(closed: nil, enabled: false) }
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return transition.update(closed: nil, enabled: true) }
    defer { IOObjectRelease(service) }
    let value =
      IORegistryEntryCreateCFProperty(
        service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      as? Bool
    return transition.update(closed: value, enabled: true)
  }
}
