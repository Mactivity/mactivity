import Foundation
import Testing
@testable import UI

@Suite("Command line tool install")
struct CommandLineToolTests {
    @Test("The command links the bundled tool into /usr/local/bin")
    func command() {
        #expect(
            CommandLineTool.installCommand(toolPath: "/Applications/Mactivity.app/Contents/Helpers/mactivity")
                == "sudo mkdir -p /usr/local/bin && "
                + "sudo ln -sf /Applications/Mactivity.app/Contents/Helpers/mactivity /usr/local/bin/mactivity"
        )
    }

    @Test("Paths with spaces or quotes are shell-quoted", arguments: [
        ("/Applications/Mactivity.app", "/Applications/Mactivity.app"),
        ("/Users/demo/My Apps/Mactivity.app", "'/Users/demo/My Apps/Mactivity.app'"),
        ("/Users/demo/Robin's/Mactivity.app", "'/Users/demo/Robin'\\''s/Mactivity.app'"),
        ("", "''"),
    ])
    func quoting(path: String, expected: String) {
        #expect(CommandLineTool.shellQuoted(path) == expected)
    }

    @Test("Status from the bundled path and the current link")
    func status() {
        let tool = "/Applications/Mactivity.app/Contents/Helpers/mactivity"
        #expect(CommandLineTool.status(toolPath: nil, linkDestination: tool) == .unavailable)
        #expect(CommandLineTool.status(toolPath: tool, linkDestination: nil) == .notInstalled)
        #expect(CommandLineTool.status(toolPath: tool, linkDestination: tool) == .installed)
        #expect(
            CommandLineTool.status(toolPath: tool, linkDestination: "/Users/demo/Downloads/Mactivity.app/Contents/Helpers/mactivity")
                == .linkedElsewhere("/Users/demo/Downloads/Mactivity.app/Contents/Helpers/mactivity")
        )
    }

    @Test("The tool isn't in Contents/MacOS, where it would collide with the app on case-insensitive APFS")
    func location() {
        #expect(CommandLineTool.bundledRelativePath == "Contents/Helpers/mactivity")
        #expect(CommandLineTool.bundledPath(in: Bundle(for: BundleMarker.self)) == nil)
    }
}

private final class BundleMarker {

    @Test("The Claude Code command uses the bundled path, quoted when it has a space (D-152)")
    func mcpCommand() {
        #expect(CommandLineTool.mcpCommand(toolPath: "/Applications/Mactivity.app/Contents/Helpers/mactivity")
            == "claude mcp add mactivity -- /Applications/Mactivity.app/Contents/Helpers/mactivity mcp")
        #expect(CommandLineTool.mcpCommand(toolPath: "/Users/a/My Apps/Mactivity.app/Contents/Helpers/mactivity")
            == "claude mcp add mactivity -- '/Users/a/My Apps/Mactivity.app/Contents/Helpers/mactivity' mcp")
    }

    @Test("The JSON for other MCP clients parses, with the path as given, quotes and all (D-197)")
    func mcpJSON() throws {
        let path = "/Applications/My \"Apps\"/Mactivity.app/Contents/Helpers/mactivity"
        let data = Data(CommandLineTool.mcpJSON(toolPath: path).utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let server = try #require((object["mcpServers"] as? [String: Any])?["mactivity"] as? [String: Any])
        #expect(server["command"] as? String == path)
        #expect(server["args"] as? [String] == ["mcp"])
    }
}
