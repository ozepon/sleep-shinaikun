import Foundation
import Darwin

// No user-controlled strings enter the privileged script. Only a numeric UID does.
struct LimitedPermission {
    static func path(uid: uid_t) -> String { "/private/etc/sudoers.d/sleep-shinaikun-\(uid)" }
    static func rule(uid: uid_t) -> String? {
        guard uid >= 501 else { return nil }
        return "# SleepShinaikun limited power toggle v1\n#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
    }
    static func isInstalled(uid: uid_t = getuid()) -> Bool {
        var info = stat()
        guard lstat(path(uid: uid), &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == 0 && (info.st_mode & 0o777) == 0o440
    }
    static func script(uid: uid_t, remove: Bool) -> String? {
        guard let rule = rule(uid: uid) else { return nil }
        let common = """
        set -eu
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        directory=/private/etc/sudoers.d
        target=\(path(uid: uid))
        [ -d "$directory" ] && [ ! -L "$directory" ]
        [ "$(/usr/bin/stat -f %u "$directory")" = 0 ]
        [ "$(/usr/bin/stat -f %Lp "$directory")" = 755 ]
        /usr/bin/grep -Eq '^[#@]includedir[[:space:]]+(/private)?/etc/sudoers[.]d([[:space:]]|$)' /private/etc/sudoers
        /usr/sbin/visudo -cf /private/etc/sudoers >/dev/null
        umask 077
        stage=$(/usr/bin/mktemp "$directory/.sleep-shinaikun-\(uid).XXXXXX")
        trap '/bin/rm -f "$stage"' EXIT
        /bin/cat > "$stage" <<'SLEEP_SHINAI_RULE'
        \(rule)SLEEP_SHINAI_RULE
        /usr/sbin/chown root:wheel "$stage"
        /bin/chmod 0440 "$stage"
        /usr/sbin/visudo -cf "$stage" >/dev/null
        if [ -e "$target" ] || [ -L "$target" ]; then
            [ -f "$target" ] && [ ! -L "$target" ]
            [ "$(/usr/bin/stat -f %u "$target")" = 0 ]
            /usr/bin/cmp -s "$stage" "$target"
        fi
        """
        if remove {
            return common + "\n/bin/rm -f \"$target\"\n/usr/sbin/visudo -cf /private/etc/sudoers >/dev/null\n"
        }
        return common + """

        /bin/mv -f "$stage" "$target"
        if ! /usr/sbin/visudo -cf /private/etc/sudoers >/dev/null; then
            /bin/rm -f "$target"
            exit 1
        fi
        """
    }
    static func appleScript(_ shell: String) -> String {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
    static func arguments(enabled: Bool) -> [String] {
        ["-n", "--", "/usr/bin/pmset", "-a", "disablesleep", enabled ? "1" : "0"]
    }
}
