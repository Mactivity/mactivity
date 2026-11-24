// swiftlint:disable type_body_length
@testable import Core
import Foundation
import Testing

/// Remote sessions' parser (D-280). Every "accepted by ssh" form below was fed to this Mac's real
/// OpenSSH with `ssh -G -F /dev/null …`, which parses and prints without connecting, and its
/// printed forwards compared with these.
struct SSHArgumentsTests {
    private func parse(_ words: String...) throws -> SSHCommandLine {
        try #require(SSHArguments.parse(["ssh"] + words))
    }

    private func local(_ value: String) -> SSHForward? {
        SSHArguments.forward(.local, value)
    }

    // MARK: Hosts

    @Test("A plain host, a user at a host, and a URI give the host alone")
    func hosts() throws {
        #expect(try parse("example.com").host == "example.com")
        #expect(try parse("kade@example.com").host == "example.com")
        #expect(try parse("ssh://kade@example.com").host == "example.com")
        let uri = try parse("ssh://kade@example.com:2222/")
        #expect(uri.host == "example.com" && uri.port == 2222)
        #expect(try parse("10.0.0.5").host == "10.0.0.5")
        #expect(try parse("kade@[2001:db8::1]").host == "2001:db8::1")
        #expect(try parse("ssh://[2001:db8::1]:2200").host == "2001:db8::1")
        #expect(try parse("ssh://[2001:db8::1]:2200").port == 2200)
    }

    @Test("A password in a destination never comes through")
    func passwordInDestination() throws {
        let parsed = try parse("ssh://kade:hunter2@example.com:22/")
        #expect(parsed.host == "example.com")
        #expect(!String(describing: parsed).contains("hunter2"))
        #expect(!String(describing: parsed).contains("kade"))
        #expect(try !String(describing: parse("kade:hunter2@example.com")).contains("hunter2"))
    }

    @Test("Something that couldn't be a host isn't kept")
    func notAHost() throws {
        #expect(try parse("exa mple").host == nil)
        #expect(try parse("host;rm -rf").host == nil)
        #expect(try parse("$(whoami)").host == nil)
        #expect(SSHArguments.hostName(String(repeating: "a", count: 300)) == nil)
    }

    @Test("Options come before or after the host, up to the first word that isn't one")
    func optionsAroundTheHost() throws {
        #expect(try parse("-p", "2222", "host").port == 2222)
        #expect(try parse("host", "-p", "2222").port == 2222)
        #expect(try parse("host", "-L", "8080:a:80").forwards.count == 1)
        let command = try parse("host", "ls", "-L", "8080:a:80")
        #expect(command.forwards.isEmpty && command.hasRemoteCommand)
    }

    @Test("`--` ends the options: the next word is the host, and after a host the rest is a command")
    func doubleDash() throws {
        #expect(try parse("-x", "--", "host").host == "host")
        let afterHost = try parse("host", "--", "-L", "8080:a:80")
        #expect(afterHost.forwards.isEmpty && afterHost.hasRemoteCommand)
        #expect(try parse("--").host == nil)
    }

    @Test("A flag's value isn't taken for the host")
    func valuesAreNotHosts() throws {
        #expect(try parse("-i", "/Users/k/.ssh/id_ed25519", "host").host == "host")
        #expect(try parse("-l", "kade", "host").host == "host")
        #expect(try parse("-F", "/tmp/config", "-E", "/tmp/log", "-S", "/tmp/ctl", "-c", "aes256-ctr", "-m", "hmac-sha2-256", "host")
            .host == "host")
        #expect(try parse("-b", "10.0.0.1", "-B", "en0", "-e", "none", "-I", "lib", "-P", "tag", "host").host == "host")
        #expect(try parse("-ikey", "host").host == "host")
    }

    // MARK: Combined flags

    @Test("Flags cluster, and the last can take its value attached or next")
    func clusters() throws {
        let attached = try parse("-NfL8080:db:5432", "host")
        #expect(attached.hasNoRemoteCommand && attached.isInBackground)
        #expect(attached.forwards.first?.listenPort == 8080)
        #expect(attached.forwards.first?.targetHost == "db")
        let next = try parse("-fNL", "8080:db:5432", "host")
        #expect(next.hasNoRemoteCommand && next.isInBackground)
        #expect(next.forwards.first?.targetPort == 5432)
        #expect(next.host == "host")
        #expect(try parse("-vvv", "-4", "-CAXYqTtnkxya", "host").host == "host")
        #expect(try parse("-tt", "host").host == "host")
        let trailing = try parse("-Np2222", "host")
        #expect(trailing.port == 2222 && trailing.hasNoRemoteCommand)
    }

    @Test("A value option with nothing after it ends the parse quietly")
    func missingValue() throws {
        let parsed = try parse("host", "-L")
        #expect(parsed.host == "host" && parsed.forwards.isEmpty)
    }

    @Test("The first -p wins, as in ssh")
    func firstPort() throws {
        #expect(try parse("-p", "22", "-p", "2222", "host").port == 22)
        #expect(try parse("-p", "2222", "-o", "Port=22", "host").port == 2222)
        #expect(try parse("-p", "99999", "host").port == nil)
    }

    // MARK: Forwards

    @Test("-L's forms")
    func localForms() throws {
        let plain = try #require(local("8080:db:5432"))
        #expect(plain.listenPort == 8080 && plain.bindAddress == nil && plain.targetHost == "db" && plain.targetPort == 5432)
        let bound = try #require(local("127.0.0.1:8080:db:5432"))
        #expect(bound.bindAddress == "127.0.0.1" && bound.listenPort == 8080 && !bound.isOpenToNetwork)
        let every = try #require(local("*:8080:db:5432"))
        #expect(every.bindAddress == "*" && every.isOpenToNetwork)
        let empty = try #require(local(":8080:db:5432"))
        #expect(empty.bindAddress == "*" && empty.isOpenToNetwork)
        let zero = try #require(local("0.0.0.0:8080:db:5432"))
        #expect(zero.isOpenToNetwork)
        let name = try #require(local("localhost:8080:db:5432"))
        #expect(!name.isOpenToNetwork)
    }

    @Test("-L with IPv6, in brackets on either side")
    func localIPv6() throws {
        let target = try #require(local("8080:[2001:db8::1]:80"))
        #expect(target.targetHost == "2001:db8::1" && target.targetPort == 80)
        let both = try #require(local("[::1]:8080:[2001:db8::1]:80"))
        #expect(both.bindAddress == "::1" && both.listenPort == 8080 && both.targetHost == "2001:db8::1" && !both.isOpenToNetwork)
    }

    @Test("-L with Unix sockets on either side")
    func localSockets() throws {
        let toSocket = try #require(local("8080:/var/run/docker.sock"))
        #expect(toSocket.listenPort == 8080 && toSocket.targetSocket == "/var/run/docker.sock")
        let fromSocket = try #require(local("/tmp/in.sock:db:5432"))
        #expect(fromSocket.listenSocket == "/tmp/in.sock" && fromSocket.listenPort == nil && fromSocket.targetPort == 5432)
        let both = try #require(local("/tmp/in.sock:/tmp/out.sock"))
        #expect(both.listenSocket == "/tmp/in.sock" && both.targetSocket == "/tmp/out.sock")
        let bound = try #require(local("127.0.0.1:8080:/tmp/out.sock"))
        #expect(bound.bindAddress == "127.0.0.1" && bound.listenPort == 8080 && bound.targetSocket == "/tmp/out.sock")
    }

    @Test("Values that aren't forwards are refused, not half read")
    func invalidForwards() {
        for value in [
            "",
            "8080",
            "abc:db:80",
            "8080:db",
            "8080:db:abc",
            "70000:db:80",
            "8080:db:70000",
            "a:b:c:d:e",
            "8080:d b:80",
            "8080:db;x:80",
        ] {
            #expect(local(value) == nil, "\(value)")
        }
        #expect(SSHArguments.forward(.dynamic, "abc") == nil)
        #expect(SSHArguments.forward(.dynamic, "a:b:c") == nil)
        #expect(SSHArguments.forward(.dynamic, "") == nil)
        #expect(SSHArguments.forward(.remote, "abc") == nil)
    }

    @Test("A bad forward counts as unreadable, beside the good ones")
    func unreadableCounted() throws {
        let parsed = try parse("-L", "8080:db:80", "-L", "nonsense", "-R", "x:y", "host")
        #expect(parsed.forwards.count == 1 && parsed.unreadableForwards == 2)
    }

    @Test("-R's forms, the SOCKS one included")
    func remoteForms() throws {
        let plain = try #require(SSHArguments.forward(.remote, "9000:localhost:3000"))
        #expect(plain.kind == .remote && plain.listenPort == 9000 && plain.targetHost == "localhost" && plain.targetPort == 3000)
        let bound = try #require(SSHArguments.forward(.remote, "0.0.0.0:9000:localhost:3000"))
        #expect(bound.bindAddress == "0.0.0.0")
        // It listens far away, so it's nothing to do with this Mac's network.
        #expect(!bound.isOpenToNetwork)
        let socks = try #require(SSHArguments.forward(.remote, "9000"))
        #expect(socks.listenPort == 9000 && socks.targetHost == nil)
        let boundSocks = try #require(SSHArguments.forward(.remote, "localhost:9000"))
        #expect(boundSocks.bindAddress == "localhost" && boundSocks.listenPort == 9000)
        let anyPort = try #require(SSHArguments.forward(.remote, "0:localhost:3000"))
        #expect(anyPort.listenPort == 0)
        let sockets = try #require(SSHArguments.forward(.remote, "/tmp/far.sock:/tmp/near.sock"))
        #expect(sockets.listenSocket == "/tmp/far.sock")
    }

    @Test("-D's forms")
    func dynamicForms() throws {
        #expect(try parse("-D", "1080", "h").forwards.first?.listenPort == 1080)
        #expect(try parse("-D1080", "h").forwards.first?.kind == .dynamic)
        let bound = try #require(SSHArguments.forward(.dynamic, "127.0.0.1:1080"))
        #expect(bound.bindAddress == "127.0.0.1" && !bound.isOpenToNetwork)
        let six = try #require(SSHArguments.forward(.dynamic, "[::1]:1080"))
        #expect(six.bindAddress == "::1" && six.listenPort == 1080)
        #expect(try #require(SSHArguments.forward(.dynamic, "*:1080")).isOpenToNetwork)
        #expect(try #require(SSHArguments.forward(.dynamic, ":1080")).isOpenToNetwork)
    }

    @Test("Many forwards, of each kind, stay in order")
    func manyForwards() throws {
        let parsed = try parse("-N", "-L", "1:a:1", "-R", "2:b:2", "-D", "3", "-L4:d:4", "host", "-L", "5:e:5")
        #expect(parsed.forwards.map(\.kind) == [.local, .remote, .dynamic, .local, .local])
        #expect(parsed.forwards.compactMap(\.listenPort) == [1, 2, 3, 4, 5])
    }

    @Test("-g opens local forwards to the network")
    func gateway() throws {
        let parsed = try parse("-g", "-L", "8080:db:80", "-D", "1080", "-R", "9:a:9", "-L", "127.0.0.1:81:db:80", "host")
        #expect(parsed.forwards.map(\.isOpenToNetwork) == [true, true, false, false])
        #expect(try parse("-L", "8080:db:80", "host").forwards.first?.isOpenToNetwork == false)
    }

    // MARK: Config options

    @Test("-o in each spelling ssh accepts")
    func configForms() throws {
        let forms = [
            ["-o", "LocalForward=8080 db:5432"],
            ["-o", "LocalForward 8080 db:5432"],
            ["-oLocalForward=8080 db:5432"],
            ["-olocalforward 8080 db:5432"],
            ["-o", "LocalForward = 8080 db:5432"],
        ]
        for form in forms {
            let parsed = try #require(SSHArguments.parse(["ssh"] + form + ["host"]))
            #expect(parsed.forwards.first?.listenPort == 8080, "\(form)")
            #expect(parsed.forwards.first?.targetHost == "db", "\(form)")
            #expect(parsed.forwards.first?.targetPort == 5432, "\(form)")
            #expect(parsed.host == "host", "\(form)")
        }
    }

    @Test("Other -o keys: forwards, port, jump, background and no command")
    func otherConfigKeys() throws {
        #expect(try parse("-o", "RemoteForward=9000 localhost:3000", "h").forwards.first?.kind == .remote)
        #expect(try parse("-o", "RemoteForward=9000", "h").forwards.first?.listenPort == 9000)
        #expect(try parse("-o", "DynamicForward=1080", "h").forwards.first?.kind == .dynamic)
        #expect(try parse("-o", "DynamicForward=127.0.0.1:1080", "h").forwards.first?.bindAddress == "127.0.0.1")
        #expect(try parse("-o", "Port=2222", "h").port == 2222)
        #expect(try parse("-o", "ProxyJump=kade@bastion:22", "h").jump == "bastion")
        #expect(try parse("-o", "ForkAfterAuthentication=yes", "h").isInBackground)
        #expect(try parse("-o", "SessionType=none", "h").hasNoRemoteCommand)
        #expect(try parse("-o", "RemoteCommand=uptime", "h").hasRemoteCommand)
        #expect(try !parse("-o", "RemoteCommand=none", "h").hasRemoteCommand)
        #expect(try parse("-o", "HostName=10.0.0.9").host == "10.0.0.9")
    }

    @Test("ClearAllForwardings wipes every forward, as scp and sftp use it")
    func clearAll() throws {
        let parsed = try parse(
            "-x",
            "-oPermitLocalCommand=no",
            "-oClearAllForwardings=yes",
            "-L",
            "1:a:1",
            "-oRemoteCommand=none",
            "-oRequestTTY=no",
            "-l",
            "kade",
            "--",
            "host",
            "-s",
            "sftp"
        )
        #expect(parsed.forwards.isEmpty)
        #expect(parsed.host == "host")
        #expect(parsed.hasRemoteCommand)
    }

    // MARK: Secrets

    /// Whatever these hold, none of it may be anywhere in the result.
    @Test("Nothing secret on a command line comes through in the parse or the session")
    func secretsStayOut() throws {
        let arguments = [
            "ssh",
            "-i", "/Users/kade/.ssh/SECRETKEYFILE",
            "-o", "ProxyCommand=sshpass -p SECRETPROXY ssh gw",
            "-o", "IdentityFile=/SECRETIDENTITY",
            "-o", "SendEnv=SECRETENV",
            "-o", "SetEnv=TOKEN=SECRETSETENV",
            "-o", "RemoteCommand=mysql -pSECRETREMOTE",
            "-o", "LocalCommand=SECRETLOCAL",
            "-o", "KnownHostsCommand=SECRETKNOWN",
            "-E", "/tmp/SECRETLOG",
            "-F", "/tmp/SECRETCONFIG",
            "-S", "/tmp/SECRETCONTROL",
            "-l", "SECRETUSER",
            "SECRETUSER:SECRETPASSWORD@example.com",
            "PGPASSWORD=SECRETCOMMAND", "psql", "-c", "select 'SECRETSQL'",
        ]
        let parsed = try #require(SSHArguments.parse(arguments))
        #expect(!String(describing: parsed).contains("SECRET"))
        #expect(parsed.host == "example.com" && parsed.hasRemoteCommand)
        let session = try #require(RemoteSessionRules.session(
            pid: 1, arguments: arguments, startedAt: nil, listeningPorts: [], peerAddress: nil, ancestors: ["zsh"]
        ))
        #expect(!String(describing: session).contains("SECRET"))
    }

    @Test("A forward can't carry anything but a host, a port or a path")
    func forwardsAreClean() {
        #expect(local("8080:$(cat /etc/passwd):80") == nil)
        #expect(local("8080:a`b`:80") == nil)
        #expect(local("8080:/tmp/x y.sock") == nil)
        #expect(local("8080:/tmp/$(id).sock") == nil)
    }

    // MARK: One-shots and other shapes

    @Test("Commands that ask and exit aren't sessions")
    func oneShots() throws {
        for words in [["-G", "h"], ["-V"], ["-Q", "cipher"], ["-O", "check", "h"], ["-Oexit", "h"]] {
            #expect(try #require(SSHArguments.parse(["ssh"] + words)).isOneShot, "\(words)")
            #expect(RemoteSessionRules.session(
                pid: 1, arguments: ["ssh"] + words, startedAt: nil, listeningPorts: [], peerAddress: nil, ancestors: []
            ) == nil)
        }
    }

    @Test("A master that rewrote its arguments says so, and nothing from its title is kept")
    func sharedConnection() throws {
        let parsed = try #require(SSHArguments.parse(["ssh: /Users/kade/.ssh/cm/SECRETPATH [mux]"]))
        #expect(parsed.isSharedConnection && parsed.host == nil)
        #expect(!String(describing: parsed).contains("SECRETPATH"))
        let split = try #require(SSHArguments.parse(["ssh:", "/Users/kade/.ssh/cm/abc", "[mux]"]))
        #expect(split.isSharedConnection)
    }

    @Test("Jump hosts lose their users and ports; none means none")
    func jumps() throws {
        #expect(try parse("-J", "bastion", "h").jump == "bastion")
        #expect(try parse("-J", "kade@bastion:2222", "h").jump == "bastion")
        #expect(try parse("-J", "a@one,b@two:22", "h").jump == "one,two")
        #expect(try parse("-J", "ssh://kade:SECRET@one:22", "h").jump == "one")
        #expect(try parse("-J", "none", "h").jump == nil)
    }

    @Test("Nothing to read gives nil, not a guess")
    func empty() {
        #expect(SSHArguments.parse([]) == nil)
    }

    // MARK: Sessions

    private func session(
        _ words: [String], ports: [UInt16] = [], peer: String? = nil, ancestors: [String] = ["zsh"]
    ) -> RemoteSession? {
        RemoteSessionRules.session(
            pid: 42, arguments: ["ssh"] + words, startedAt: Date(timeIntervalSince1970: 1), listeningPorts: ports, peerAddress: peer,
            ancestors: ancestors
        )
    }

    @Test("A session's kind")
    func kinds() {
        #expect(session(["host"])?.kind == .shell)
        #expect(session(["-N", "-L", "1:a:1", "host"])?.kind == .tunnel)
        #expect(session(["-f", "-L", "1:a:1", "host"])?.kind == .tunnel)
        #expect(session(["-f", "host", "sleep", "9"])?.kind == .command)
        #expect(session(["-w", "0:0", "host"])?.kind == .tunnel)
        #expect(session(["-L", "1:a:1", "host"])?.kind == .shell)
        #expect(session(["host", "uptime"])?.kind == .command)
        #expect(session(["-W", "db:22", "bastion"])?.kind == .proxy)
    }

    @Test("A -W helper another ssh started is that ssh's, not a row of its own")
    func proxyHelper() {
        #expect(session(["-W", "[db]:22", "bastion"], ancestors: ["ssh", "zsh"]) == nil)
        #expect(session(["-W", "[db]:22", "bastion"], ancestors: ["sh", "ssh", "zsh"]) == nil)
        #expect(session(["-W", "db:22", "bastion"], ancestors: ["zsh"]) != nil)
    }

    @Test("Ports it listens on and doesn't name are set elsewhere; named ones are checked")
    func listeningPorts() throws {
        let found = try #require(session(
            ["-N", "-L", "8080:db:80", "-D", "1080", "-R", "9000:a:9", "-L", "7070:db:70", "host"],
            ports: [1080, 8080, 8443]
        ))
        let local = found.forwards.filter { $0.kind == .local }
        #expect(found.forwards.first { $0.listenPort == 8080 }?.isListening == true)
        #expect(found.forwards.first { $0.listenPort == 1080 }?.isListening == true)
        // It says it forwards this, but no port's open: maybe taken already, or still connecting.
        #expect(found.forwards.first { $0.listenPort == 7070 }?.isListening == false)
        // Far away: this Mac can't tell.
        #expect(found.forwards.first { $0.kind == .remote }?.isListening == nil)
        let extra = try #require(local.first { $0.listenPort == 8443 })
        #expect(extra.isFromSocketOnly && extra.targetHost == nil)
        #expect(found.forwards.count == 5)
    }

    @Test("Remote port 9000 isn't this Mac's port 9000")
    func remotePortDoesNotHideALocalOne() throws {
        let found = try #require(session(["-R", "9000:a:9", "host"], ports: [9000]))
        #expect(found.forwards.count == 2)
        #expect(found.forwards.last?.isFromSocketOnly == true)
    }

    @Test("A shared connection's host comes from its open socket; others' never do")
    func peers() {
        #expect(RemoteSessionRules.session(
            pid: 1, arguments: ["ssh: /c [mux]"], startedAt: nil, listeningPorts: [], peerAddress: "203.0.113.7", ancestors: []
        )?.host == "203.0.113.7")
        #expect(session(["alias"], peer: "203.0.113.7")?.host == "alias")
    }

    @Test("Arguments macOS wouldn't give still make a row, with no host")
    func unreadable() {
        let found = RemoteSessionRules.session(
            pid: 1, arguments: [], startedAt: nil, listeningPorts: [2222], peerAddress: nil, ancestors: []
        )
        #expect(found?.host == nil)
        #expect(found?.forwards.first?.listenPort == 2222)
    }

    @Test("Who started it shows only when that says something")
    func startedBy() {
        #expect(session(["git@github.com", "git-upload-pack"], ancestors: ["git", "zsh"])?.startedBy == "git")
        #expect(session(["host"], ancestors: ["zsh", "Terminal"])?.startedBy == nil)
        #expect(session(["host"], ancestors: [])?.startedBy == nil)
    }

    @Test("Longest open first")
    func order() {
        let old = RemoteSession(pid: 2, kind: .shell, host: "a", startedAt: Date(timeIntervalSince1970: 1))
        let new = RemoteSession(pid: 1, kind: .shell, host: "b", startedAt: Date(timeIntervalSince1970: 2))
        let unknown = RemoteSession(pid: 3, kind: .shell, host: "c", startedAt: nil)
        #expect(RemoteSessionRules.sorted([unknown, new, old]).map(\.pid) == [2, 1, 3])
    }
}

// swiftlint:enable type_body_length
