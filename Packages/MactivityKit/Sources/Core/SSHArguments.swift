import Foundation

/// Parses what `ssh` itself would: OpenSSH's option letters, in clusters, with values attached or
/// next, and options after the host until the first word that isn't one. Checked against
/// `ssh -G -F /dev/null` on this Mac's OpenSSH (D-280). Pure.
public enum SSHArguments {
    /// OpenSSH's options that take a value (`ssh.c`'s getopt string, with -D, -L, -R among them).
    fileprivate static let takesValue = Set("bceilmopBDEFIJLOPQRSwW")

    /// `arguments` starts with argv[0]. Nil when there are none to read.
    public static func parse(_ arguments: [String]) -> SSHCommandLine? {
        guard let first = arguments.first else {
            return nil
        }
        // A connection master rewrites its arguments: "ssh: /Users/x/.ssh/cm/abc [mux]".
        if first.hasPrefix("ssh: ") || arguments.contains(where: { $0.hasSuffix("[mux]") }) {
            var shared = SSHCommandLine()
            shared.isSharedConnection = true
            shared.hasNoRemoteCommand = true
            return shared
        }
        var scan = Scan(words: Array(arguments.dropFirst()))
        scan.run()
        return scan.finished()
    }

    /// One walk along the words, as ssh's own loop goes.
    private struct Scan {
        let words: [String]
        var index = 0
        var parsed = SSHCommandLine()
        var gateway = false
        var clearsForwards = false
        var hasHost = false

        init(words: [String]) {
            self.words = words
        }

        mutating func run() {
            while index < words.count {
                let word = words[index]
                index += 1
                let goesOn = word == "--" ? endOfOptions() : word.hasPrefix("-") && word.count > 1 ? cluster(word) : positional(word)
                if !goesOn {
                    return
                }
            }
        }

        /// `--`: the next word is the host, or after a host the rest is the command.
        private mutating func endOfOptions() -> Bool {
            if hasHost {
                parsed.hasRemoteCommand = index < words.count
                return false
            }
            guard index < words.count else {
                return false
            }
            parsed.host = SSHArguments.destination(words[index], into: &parsed)
            hasHost = true
            index += 1
            return true
        }

        private mutating func positional(_ word: String) -> Bool {
            if hasHost {
                // The remote command, which is never read: it's where secrets are.
                parsed.hasRemoteCommand = true
                return false
            }
            parsed.host = SSHArguments.destination(word, into: &parsed)
            hasHost = true
            return true
        }

        /// `-NfL8080:db:80`: flags, up to one that takes a value, attached or next.
        private mutating func cluster(_ word: String) -> Bool {
            var letters = Substring(word.dropFirst())
            while let letter = letters.first {
                letters = letters.dropFirst()
                guard SSHArguments.takesValue.contains(letter) else {
                    flag(letter)
                    continue
                }
                if !letters.isEmpty {
                    SSHArguments.apply(letter, String(letters), to: &parsed, clearsForwards: &clearsForwards)
                    return true
                }
                guard index < words.count else {
                    return false
                }
                SSHArguments.apply(letter, words[index], to: &parsed, clearsForwards: &clearsForwards)
                index += 1
                return true
            }
            return true
        }

        private mutating func flag(_ letter: Character) {
            switch letter {
            case "N": parsed.hasNoRemoteCommand = true
            case "f": parsed.isInBackground = true
            case "G", "V": parsed.isOneShot = true
            case "g": gateway = true
            case "s": parsed.hasRemoteCommand = true
            default: break
            }
        }

        func finished() -> SSHCommandLine {
            var result = parsed
            if clearsForwards {
                result.forwards = []
                result.unreadableForwards = 0
            }
            if gateway {
                // `-g`: its local forwards listen on every interface.
                result.forwards = result.forwards.map { forward in
                    forward.kind != .remote && forward.bindAddress == nil && forward.listenPort != nil
                        ? SSHForward(
                            kind: forward.kind, bindAddress: "*", listenPort: forward.listenPort, targetHost: forward.targetHost,
                            targetPort: forward.targetPort, targetSocket: forward.targetSocket
                        )
                        : forward
                }
            }
            return result
        }
    }

    fileprivate static func apply(_ letter: Character, _ value: String, to parsed: inout SSHCommandLine, clearsForwards: inout Bool) {
        switch letter {
        case "L": addForward(.local, value, to: &parsed)
        case "R": addForward(.remote, value, to: &parsed)
        case "D": addForward(.dynamic, value, to: &parsed)
        // ssh keeps the first port it's given.
        case "p": parsed.port = parsed.port ?? UInt16(value)
        case "J": parsed.jump = jumpHosts(value)
        case "W": parsed.isProxy = true
        case "w": parsed.hasTunnelDevice = true
        case "O", "Q": parsed.isOneShot = true
        case "o": applyConfig(value, to: &parsed, clearsForwards: &clearsForwards)
        default: break
        }
    }

    /// `-o Key=Value`, `-o "Key Value"`. Only the keys below are looked at; the rest, ProxyCommand
    /// and IdentityFile among them, are dropped unread.
    private static func applyConfig(_ option: String, to parsed: inout SSHCommandLine, clearsForwards: inout Bool) {
        let text = option.trimmingCharacters(in: .whitespaces)
        guard let split = text.firstIndex(where: { $0 == "=" || $0 == " " || $0 == "\t" }) else {
            return
        }
        let key = text[..<split].lowercased()
        let value = String(text[text.index(after: split)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t=\"'"))
        let yes = ["yes", "true"].contains(value.lowercased())
        switch key {
        case "localforward": addForward(.local, colonForm(value), to: &parsed)
        case "remoteforward": addForward(.remote, colonForm(value), to: &parsed)
        case "dynamicforward": addForward(.dynamic, value, to: &parsed)
        case "hostname": parsed.host = parsed.host ?? hostName(value)
        case "port": parsed.port = parsed.port ?? UInt16(value)
        case "proxyjump": parsed.jump = jumpHosts(value)
        case "forkafterauthentication": parsed.isInBackground = parsed.isInBackground || yes
        case "clearallforwardings": clearsForwards = yes
        case "sessiontype": parsed.hasNoRemoteCommand = parsed.hasNoRemoteCommand || value.lowercased() == "none"
        case "remotecommand": parsed.hasRemoteCommand = parsed.hasRemoteCommand || value.lowercased() != "none"
        default: break
        }
    }

    /// In a config line the listen side and the target are two words: "8080 localhost:80".
    private static func colonForm(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: ":")
    }

    private static func addForward(_ kind: SSHForward.Kind, _ value: String, to parsed: inout SSHCommandLine) {
        if let forward = forward(kind, value) {
            parsed.forwards.append(forward)
        } else {
            parsed.unreadableForwards += 1
        }
    }

    /// `host`, `user@host`, `user:password@host`, `ssh://user@host:2222/`.
    fileprivate static func destination(_ word: String, into parsed: inout SSHCommandLine) -> String? {
        var text = word
        let isURI = text.lowercased().hasPrefix("ssh://")
        if isURI {
            text = String(text.dropFirst("ssh://".count))
            if let slash = text.firstIndex(of: "/") {
                text = String(text[..<slash])
            }
        }
        // Everything before the last @ is a user, and maybe a password. Never kept.
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        if isURI {
            let fields = colonFields(text)
            if fields.count == 2 {
                parsed.port = parsed.port ?? UInt16(fields[1])
            }
            return fields.first.flatMap(hostName)
        }
        return hostName(text.hasPrefix("[") && text.hasSuffix("]") ? String(text.dropFirst().dropLast()) : text)
    }

    private static let hostCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:%"))

    /// A host name or address, or nil for anything that couldn't be one.
    static func hostName(_ text: String) -> String? {
        let isHost = !text.isEmpty && text.count <= 253 && !text.hasPrefix("-") && text.unicodeScalars.allSatisfy(hostCharacters.contains)
        return isHost ? text : nil
    }

    /// "user@bastion:22,other" → "bastion,other".
    private static func jumpHosts(_ value: String) -> String? {
        guard value.lowercased() != "none" else {
            return nil
        }
        let hosts = value.split(separator: ",").compactMap { part -> String? in
            var scratch = SSHCommandLine()
            var text = String(part)
            if !text.lowercased().hasPrefix("ssh://") {
                if let at = text.lastIndex(of: "@") {
                    text = String(text[text.index(after: at)...])
                }
                return colonFields(text).first.flatMap(hostName)
            }
            return destination(text, into: &scratch)
        }
        return hosts.isEmpty ? nil : hosts.joined(separator: ",")
    }

    /// Splits on colons outside brackets, and takes the brackets off: "[::1]:80" → ["::1", "80"].
    private static func colonFields(_ text: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var inBrackets = false
        for character in text {
            switch character {
            case "[" where field.isEmpty: inBrackets = true
            case "]" where inBrackets: inBrackets = false
            case ":" where !inBrackets:
                fields.append(field)
                field = ""
            default: field.append(character)
            }
        }
        fields.append(field)
        return fields
    }

    private static func isSocket(_ text: String) -> Bool {
        text.contains("/")
    }

    private static let pathCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-~%+"))

    private static func socketPath(_ text: String) -> String? {
        isSocket(text) && text.count <= 1024 && text.unicodeScalars.allSatisfy(pathCharacters.contains) ? text : nil
    }

    private static func portNumber(_ text: String) -> UInt16? {
        !text.isEmpty && text.allSatisfy(\.isNumber) ? UInt16(text) : nil
    }

    /// An empty bind is "every interface"; a missing one stays nil, the default.
    private static func bind(_ text: String) -> String? {
        if text.isEmpty {
            return "*"
        }
        return text == "*" ? "*" : hostName(text)
    }

    /// One `-L`, `-R` or `-D` value, or nil if it isn't a valid one. The forms are OpenSSH's own
    /// (`ssh(1)`): [bind:]port:host:hostport, [bind:]port:socket, socket:host:hostport,
    /// socket:socket; -R also [bind:]port alone, and -D [bind:]port.
    public static func forward(_ kind: SSHForward.Kind, _ value: String) -> SSHForward? {
        let fields = colonFields(value)
        if kind == .dynamic {
            return dynamicForward(fields)
        }
        switch fields.count {
        case 1:
            // -R port: a SOCKS proxy on the far side. -L has no one-part form.
            return kind == .remote ? portNumber(fields[0]).map { SSHForward(kind: .remote, listenPort: $0) } : nil
        case 2: return twoFields(kind, fields)
        case 3: return threeFields(kind, fields)
        case 4:
            guard let address = bind(fields[0]), let port = portNumber(fields[1]), let host = hostName(fields[2]),
                  let targetPort = portNumber(fields[3]) else {
                return nil
            }
            return SSHForward(kind: kind, bindAddress: address, listenPort: port, targetHost: host, targetPort: targetPort)
        default:
            return nil
        }
    }

    private static func dynamicForward(_ fields: [String]) -> SSHForward? {
        switch fields.count {
        case 1:
            return portNumber(fields[0]).map { SSHForward(kind: .dynamic, listenPort: $0) }
        case 2:
            guard let port = portNumber(fields[1]), let address = bind(fields[0]) else {
                return nil
            }
            return SSHForward(kind: .dynamic, bindAddress: address, listenPort: port)
        default:
            return nil
        }
    }

    /// port:socket, socket:socket, or -R bind:port.
    private static func twoFields(_ kind: SSHForward.Kind, _ fields: [String]) -> SSHForward? {
        if let port = portNumber(fields[0]), let target = socketPath(fields[1]) {
            return SSHForward(kind: kind, listenPort: port, targetSocket: target)
        }
        if let listen = socketPath(fields[0]), let target = socketPath(fields[1]) {
            return SSHForward(kind: kind, listenSocket: listen, targetSocket: target)
        }
        if kind == .remote, let address = bind(fields[0]), let port = portNumber(fields[1]) {
            return SSHForward(kind: .remote, bindAddress: address, listenPort: port)
        }
        return nil
    }

    /// bind:port:socket, port:host:hostport, socket:host:hostport.
    private static func threeFields(_ kind: SSHForward.Kind, _ fields: [String]) -> SSHForward? {
        if let target = socketPath(fields[2]) {
            guard let address = bind(fields[0]), let port = portNumber(fields[1]) else {
                return nil
            }
            return SSHForward(kind: kind, bindAddress: address, listenPort: port, targetSocket: target)
        }
        guard let host = hostName(fields[1]), let targetPort = portNumber(fields[2]) else {
            return nil
        }
        if let listen = socketPath(fields[0]) {
            return SSHForward(kind: kind, listenSocket: listen, targetHost: host, targetPort: targetPort)
        }
        return portNumber(fields[0]).map { SSHForward(kind: kind, listenPort: $0, targetHost: host, targetPort: targetPort) }
    }
}
