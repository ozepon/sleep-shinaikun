import Foundation
var state = LidTransition()
var checks = 0
func check(_ actual: Bool, _ expected: Bool) { precondition(actual == expected); checks += 1 }
check(state.update(closed: true, enabled: true), false)
check(state.update(closed: false, enabled: true), false)
check(state.update(closed: true, enabled: true), true)
check(state.update(closed: true, enabled: true), false)
check(state.update(closed: false, enabled: false), false)
check(state.update(closed: true, enabled: true), false)
check(state.update(closed: nil, enabled: true), false)
check(state.update(closed: true, enabled: true), false)
check(state.update(closed: false, enabled: true), false)
check(state.update(closed: true, enabled: true), true)
print("Lid transition: \(checks) checks passed")
