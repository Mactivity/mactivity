import AppKit
import Core
import SwiftUI

/// Settings → General's "Command Line Tool" section (E6). It never installs anything itself:
/// it shows the one `sudo ln -s` command for the user to run in Terminal, because writing to
/// `/usr/local/bin` needs admin rights and Mactivity never asks for them.
public struct CommandLineToolSettings: View {
    /// The tool inside this app: `Mactivity.app/Contents/Helpers/mactivity`. Nil when the build
    /// doesn't contain it.
    private let toolPath: String?
    @State private var showsInstructions = false
    @State private var copied = false

    @State private var copiedMCP = false
    /// Bumped when Mactivity comes back to the front: installed in Terminal, the status catches up (D-197).
    @State private var checks = 0

    public init(toolPath: String? = CommandLineTool.bundledPath()) {
        self.toolPath = toolPath
    }

    public var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(status.title)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Install Command Line Tool…", bundle: .strings)) {
                        copied = false
                        showsInstructions = true
                    }
                    .disabled(toolPath == nil)
                }
            } label: {
                // The tool's name, as typed in Terminal.
                Text(verbatim: "mactivity")
            }
            // `mactivity mcp` for coding agents (D-152): the bundled path, so it works uninstalled.
            LabeledContent {
                // Claude Code's one command, and the JSON most other clients (Cursor, Codex…) take (D-197).
                Menu(copiedMCP ? String(localized: "Copied", bundle: .strings) : String(localized: "Copy Setup", bundle: .strings)) {
                    Button(String(localized: "Claude Code Command", bundle: .strings)) {
                        copyMCP { CommandLineTool.mcpCommand(toolPath: $0) }
                    }
                    Button(String(localized: "JSON for Other Clients", bundle: .strings)) {
                        copyMCP { CommandLineTool.mcpJSON(toolPath: $0) }
                    }
                }
                .fixedSize()
                .disabled(toolPath == nil)
            } label: {
                Text("AI agents (MCP)", bundle: .strings)
                Text("Lets Claude Code, Codex or Cursor ask what your Mac is doing. Read-only.", bundle: .strings)
            }
        } header: {
            Text("Command Line", bundle: .strings)
        } footer: {
            Text("`mactivity top --memory --json` for scripts. Read-only: it can't stop or quit anything.", bundle: .strings)
                .foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in checks += 1 }
        .sheet(isPresented: $showsInstructions) {
            if let toolPath {
                instructions(CommandLineTool.installCommand(toolPath: toolPath))
            }
        }
    }

    private var status: CommandLineTool.Status {
        _ = checks
        return CommandLineTool.status(toolPath: toolPath, linkDestination: CommandLineTool.currentLinkDestination())
    }

    private func copyMCP(_ text: (String) -> String) {
        guard let toolPath else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(toolPath), forType: .string)
        copiedMCP = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedMCP = false
        }
    }

    private func instructions(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Install the Command Line Tool", bundle: .strings)
                .font(Tokens.Typography.cardTitle)
            Text("Run this in Terminal. It asks for your password and links `mactivity` into /usr/local/bin.", bundle: .strings)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(command)
                .font(Tokens.Typography.code)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Tokens.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Surfaces.inset, in: Tokens.Shapes.card)
            Text("If you move Mactivity, run it again. To remove it: `sudo rm \(CommandLineTool.linkPath)`", bundle: .strings)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(copied ? String(localized: "Copied", bundle: .strings) : String(localized: "Copy Command", bundle: .strings)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                Button(String(localized: "Done", bundle: .strings)) { showsInstructions = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: Tokens.Layout.onboardingWidth)
    }
}

/// Where the tool is and how to link it. Pure except for the two file-system reads, which are
/// separate so the logic is testable.
public enum CommandLineTool {
    /// Adds `mactivity mcp` to Claude Code (D-152); other clients take the same path and "mcp".
    public static func mcpCommand(toolPath: String) -> String {
        let quoted = toolPath.contains(" ") ? "'\(toolPath)'" : toolPath
        return "claude mcp add mactivity -- \(quoted) mcp"
    }

    /// The `mcpServers` entry that JSON-configured MCP clients read (Cursor, Windsurf, Claude Desktop…).
    public static func mcpJSON(toolPath: String) -> String {
        let escaped = toolPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "mcpServers": {
            "mactivity": { "command": "\(escaped)", "args": ["mcp"] }
          }
        }
        """
    }

    public static let linkPath = "/usr/local/bin/mactivity"
    /// Relative to the app bundle. Not `Contents/MacOS/mactivity`: on the default
    /// case-insensitive APFS that path is the app's own `Mactivity` executable.
    public static let bundledRelativePath = "Contents/Helpers/mactivity"

    public enum Status: Equatable, Sendable {
        case unavailable, notInstalled, installed, linkedElsewhere(String)

        public var title: String {
            switch self {
            case .unavailable: String(localized: "Not in this build", bundle: .strings, comment: "The command line tool")
            case .notInstalled: String(localized: "Not installed", bundle: .strings, comment: "The command line tool")
            case .installed: String(localized: "Installed", bundle: .strings, comment: "The command line tool")
            case .linkedElsewhere: String(localized: "Points to another copy", bundle: .strings, comment: "The command line tool")
            }
        }
    }

    public static func bundledPath(in bundle: Bundle = .main) -> String? {
        let url = bundle.bundleURL.appendingPathComponent(bundledRelativePath)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    /// `sudo mkdir -p /usr/local/bin && sudo ln -sf '<tool>' /usr/local/bin/mactivity`. The
    /// folder doesn't exist on a fresh Apple silicon Mac; `-f` replaces a link to an older copy.
    public static func installCommand(toolPath: String) -> String {
        let folder = (linkPath as NSString).deletingLastPathComponent
        return "sudo mkdir -p \(folder) && sudo ln -sf \(shellQuoted(toolPath)) \(linkPath)"
    }

    /// Single-quoted for the shell unless it's plainly safe.
    public static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
        if !path.isEmpty, path.unicodeScalars.allSatisfy(safe.contains) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func status(toolPath: String?, linkDestination: String?) -> Status {
        guard let toolPath else {
            return .unavailable
        }
        guard let linkDestination else {
            return .notInstalled
        }
        let resolved = (linkDestination as NSString).standardizingPath
        return resolved == (toolPath as NSString).standardizingPath ? .installed : .linkedElsewhere(resolved)
    }

    /// Where `/usr/local/bin/mactivity` points, if it's a symlink. Read-only.
    public static func currentLinkDestination() -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
    }
}
