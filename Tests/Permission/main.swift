import Cocoa
import Darwin

var count = 0
func check(_ condition: Bool, _ name: String) {
    guard condition else { print("FAIL: \(name)"); exit(1) }
    count += 1
    print("PASS: \(name)")
}
func run(_ executable: String, _ arguments: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
}
check(LimitedPermission.rule(uid: 0) == nil, "root is not an installation target")
check(LimitedPermission.rule(uid: 500) == nil, "system UIDs are rejected")
let expected = "# SleepShinaikun limited power toggle v1\n#501 ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
check(LimitedPermission.rule(uid: 501) == expected, "rule permits exactly two fixed commands for one UID")
check(!expected.contains("NOPASSWD: ALL"), "no unrestricted root permission")
check(!expected.contains("*"), "no wildcard arguments")
check(!expected.contains("SETENV"), "no environment override permission")
check(LimitedPermission.arguments(enabled: true) == ["-n", "--", "/usr/bin/pmset", "-a", "disablesleep", "1"], "enable uses noninteractive fixed argv")
check(LimitedPermission.arguments(enabled: false).last == "0", "disable uses boolean-selected zero")
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sleep-permission-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let rule = folder.appendingPathComponent("rule")
try expected.write(to: rule, atomically: true, encoding: .utf8)
check(run("/usr/sbin/visudo", ["-cf", rule.path]) == 0, "system visudo accepts generated rule")
for remove in [false, true] {
    let shell = LimitedPermission.script(uid: 501, remove: remove)!
    let file = folder.appendingPathComponent(remove ? "remove.sh" : "install.sh")
    try shell.write(to: file, atomically: true, encoding: .utf8)
    check(run("/bin/sh", ["-n", file.path]) == 0, "shell parses \(remove ? "removal" : "installation") without execution")
    check(shell.contains("[ ! -L \"$target\" ]"), "reject target symlinks")
    check(shell.contains("/usr/bin/cmp -s \"$stage\" \"$target\""), "refuse to overwrite or remove unexpected content")
    check(shell.contains("/usr/sbin/visudo -cf /private/etc/sudoers"), "validate existing and final sudo policy")
    check(shell.contains("/bin/chmod 0440"), "policy is not writable by ordinary user")
    var error: NSDictionary?
    let script = NSAppleScript(source: LimitedPermission.appleScript(shell))
    check(script?.compileAndReturnError(&error) == true && error == nil, "AppleScript compiles without requesting privilege")
}
print("Limited-permission checks passed: \(count). No installation or privileged commands were executed.")

// Exercise the installer transaction in an isolated user-owned fixture.
// Replace only system paths, root ownership checks and chown; never run as root.
let fixture = folder.appendingPathComponent("sudoers.d")
try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
let mainFile = folder.appendingPathComponent("sudoers")
try ("@includedir " + fixture.path + "\n").write(to: mainFile, atomically: true, encoding: .utf8)
let target = fixture.appendingPathComponent("sleep-shinaikun-501")
func transaction(remove: Bool) -> Int32 {
    var shell = LimitedPermission.script(uid: 501, remove: remove)!
    shell = shell.replacingOccurrences(of: "/private/etc/sudoers.d", with: fixture.path)
    shell = shell.replacingOccurrences(of: "/private/etc/sudoers", with: mainFile.path)
    shell = shell.replacingOccurrences(of: "\" = 0 ]", with: "\" = \(getuid()) ]")
    shell = shell.replacingOccurrences(of: "/usr/sbin/chown root:wheel \"$stage\"", with: ": # ownership change is intentionally not performed in this fixture")
    let lines = shell.components(separatedBy: "\n").map { line in
        line.contains("/usr/bin/grep -Eq") ? "/usr/bin/grep -Fqx '@includedir \(fixture.path)' \(mainFile.path)" : line
    }
    shell = lines.joined(separator: "\n")
    let script = folder.appendingPathComponent("transaction.sh")
    try! shell.write(to: script, atomically: true, encoding: .utf8)
    return run("/bin/sh", [script.path])
}
check(transaction(remove: false) == 0, "isolated install transaction succeeds")
check((try? String(contentsOf: target, encoding: .utf8)) == expected, "installed fixture equals exact narrow rule")
check(transaction(remove: false) == 0, "isolated reinstall is idempotent")
check(transaction(remove: true) == 0 && !FileManager.default.fileExists(atPath: target.path), "isolated uninstall removes only managed rule")
let other = fixture.appendingPathComponent("other-policy")
try "# unrelated\n".write(to: other, atomically: true, encoding: .utf8)
try "# unexpected content\n".write(to: target, atomically: true, encoding: .utf8)
check(transaction(remove: false) != 0, "refuse overwrite of unknown policy")
check(transaction(remove: true) != 0, "refuse deletion of unknown policy")
check((try? String(contentsOf: target, encoding: .utf8)) == "# unexpected content\n", "unknown policy is preserved")
try FileManager.default.removeItem(at: target)
try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
check(transaction(remove: false) != 0 && transaction(remove: true) != 0, "refuse symlink on install and removal")
check((try? String(contentsOf: other, encoding: .utf8)) == "# unrelated\n", "unrelated policy is preserved")
let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.path).filter { $0.hasPrefix(".sleep-shinaikun-") }
check(temporaryFiles.isEmpty, "transaction temporary files are cleaned on success and failure")
print("Total limited-permission checks passed: \(count). Fixture only; real sudo configuration was not modified.")
