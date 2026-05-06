import Foundation

public enum TransparentRoutingScript {
    private static let pfAnchorName = "com.antigravityporter"
    private static let pfAnchorFile = "/etc/pf.anchors/com.antigravityporter"
    private static let pfConfFile = "/etc/pf.conf"

    public static let hosts = [
        "cloudcode-pa.googleapis.com"
    ]

    public static func enable(proxyPort: Int) -> String {
        let hostLines = hosts.flatMap { ["127.0.0.1 \($0)", "::ffff:127.0.0.1 \($0)"] }.joined(separator: "\n")
        return """
        set -e
        anchor_name="\(pfAnchorName)"
        anchor_file="\(pfAnchorFile)"
        token_file="/etc/pf.anchors/com.antigravityporter.token"
        pf_conf="\(pfConfFile)"
        pf_backup="/etc/pf.conf.antigravityporter.bak"
        hosts_backup="$(mktemp)"
        hosts_tmp="$(mktemp)"
        anchor_tmp="$(mktemp)"
        tmp_pf="$(mktemp)"
        cp /etc/hosts "$hosts_backup"
        cleanup() { rm -f "$hosts_backup" "$hosts_tmp" "$anchor_tmp" "$tmp_pf"; }
        rollback() {
          cat "$hosts_backup" > /etc/hosts
          if [ -f "$pf_backup" ]; then cat "$pf_backup" > "$pf_conf"; fi
          /sbin/pfctl -a "$anchor_name" -F all >/dev/null 2>&1 || true
          rm -f "$anchor_file" "$token_file"
          /sbin/pfctl -f "$pf_conf" >/dev/null 2>&1 || true
          /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
          /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
        }
        trap 'status=$?; if [ "$status" -ne 0 ]; then rollback; fi; cleanup; exit "$status"' EXIT
        awk 'BEGIN{skip=0} $0=="# AntigravityPorter START"{skip=1;next} $0=="# AntigravityPorter END"{skip=0;next} skip==0{print}' /etc/hosts > "$hosts_tmp"
        cat >> "$hosts_tmp" <<'EOF'
        # AntigravityPorter START
        \(hostLines)
        # AntigravityPorter END
        EOF
        cat > "$anchor_tmp" <<'EOF'
        rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port \(proxyPort)
        EOF
        awk '
        BEGIN{skip=0; inserted=0}
        $0=="# AntigravityPorter PF START"{skip=1;next}
        $0=="# AntigravityPorter PF END"{skip=0;next}
        skip==1{next}
        {
          print
          if (inserted==0 && $0 ~ /^rdr-anchor[ \t]/) {
            print "# AntigravityPorter PF START"
            print "rdr-anchor \\"com.antigravityporter\\""
            print "# AntigravityPorter PF END"
            inserted=1
          }
        }
        END{
          if (inserted==0) {
            print "# AntigravityPorter PF START"
            print "rdr-anchor \\"com.antigravityporter\\""
            print "# AntigravityPorter PF END"
          }
        }' "$pf_conf" > "$tmp_pf"
        /sbin/pfctl -nf "$tmp_pf"
        [ -f "$pf_backup" ] || cp "$pf_conf" "$pf_backup"
        cat "$hosts_tmp" > /etc/hosts
        cat "$anchor_tmp" > "$anchor_file"
        cat "$tmp_pf" > "$pf_conf"
        /sbin/pfctl -f "$pf_conf"
        /sbin/pfctl -a "$anchor_name" -f "$anchor_file"
        pf_enable_output="$(/sbin/pfctl -E 2>&1 || true)"
        printf "%s\\n" "$pf_enable_output" > "$token_file"
        /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
        /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
        trap - EXIT
        cleanup
        """
    }

    public static func disable() -> String {
        """
        set -e
        tmp="$(mktemp)"
        awk 'BEGIN{skip=0} $0=="# AntigravityPorter START"{skip=1;next} $0=="# AntigravityPorter END"{skip=0;next} skip==0{print}' /etc/hosts > "$tmp"
        cat "$tmp" > /etc/hosts
        rm -f "$tmp"
        pf_conf="\(pfConfFile)"
        tmp_pf="$(mktemp)"
        awk 'BEGIN{skip=0} $0=="# AntigravityPorter PF START"{skip=1;next} $0=="# AntigravityPorter PF END"{skip=0;next} skip==0{print}' "$pf_conf" > "$tmp_pf"
        /sbin/pfctl -nf "$tmp_pf"
        cat "$tmp_pf" > "$pf_conf"
        rm -f "$tmp_pf"
        /sbin/pfctl -a com.antigravityporter -F all >/dev/null 2>&1 || true
        if [ -f /etc/pf.anchors/com.antigravityporter.token ]; then
          token="$(awk '/Token/ {print $3; exit}' /etc/pf.anchors/com.antigravityporter.token)"
          if [ -n "$token" ]; then /sbin/pfctl -X "$token" >/dev/null 2>&1 || true; fi
        fi
        rm -f /etc/pf.anchors/com.antigravityporter
        rm -f /etc/pf.anchors/com.antigravityporter.token
        /sbin/pfctl -f "$pf_conf" >/dev/null 2>&1 || true
        /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
        /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
        """
    }
}

public enum TransparentRoutingManagerError: Error, LocalizedError, Equatable {
    case commandFailed(status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(status, stderr):
            "transparent routing command failed (\(status)): \(stderr)"
        }
    }
}

public struct TransparentRoutingManager: Sendable {
    public init() {}

    public func enable(proxyPort: Int) throws {
        try runPrivilegedShell(TransparentRoutingScript.enable(proxyPort: proxyPort))
    }

    public func disable() throws {
        try runPrivilegedShell(TransparentRoutingScript.disable())
    }

    private func runPrivilegedShell(_ shellScript: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \(appleScriptString(shellScript)) with administrator privileges"
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TransparentRoutingManagerError.commandFailed(status: process.terminationStatus, stderr: error)
        }
    }

    private func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        + "\""
    }
}
