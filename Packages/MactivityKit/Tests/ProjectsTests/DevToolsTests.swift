import Foundation
@testable import Projects
import Testing

/// Background dev tools (D-228).
struct DevToolsTests {
    private func identify(_ name: String, _ arguments: String = "") -> String? {
        DevToolRules.identify(name: name, arguments: [name] + arguments.split(separator: " ").map(String.init))?.name
    }

    @Test("Language servers by name or by the script an interpreter runs")
    func languageServers() {
        #expect(identify("rust-analyzer") == "rust-analyzer")
        #expect(identify("sourcekit-lsp") == "sourcekit-lsp")
        #expect(identify("node", "/Applications/Cursor.app/…/typescript/lib/tsserver.js --serverMode partialSemantic") ==
            "TypeScript server")
        #expect(identify("node", "/Users/a/.vscode/extensions/ms-python.vscode-pylance/dist/server.bundle.js") == "Pylance")
        #expect(identify("python3.13", "-m pylsp") == "Python LSP server")
        #expect(identify("node", "/Users/a/app/node_modules/.bin/next dev") == nil)
        #expect(identify("Safari") == nil)
    }

    @Test("Editors' language servers run in their Electron helper (VS Code, Cursor)")
    func editorHelpers() {
        #expect(identify(
            "Code Helper (Plugin)",
            "--ms-enable-electron-run-as-node /Applications/Visual Studio Code.app/…/typescript/lib/tsserver.js --serverMode semantic"
        ) == "TypeScript server")
        #expect(identify(
            "Cursor Helper (Plugin)",
            "--ms-enable-electron-run-as-node /Users/a/.cursor/extensions/dbaeumer.vscode-eslint/server/out/eslintServer.js"
        ) == "ESLint server")
        // The extension host itself isn't a tool.
        #expect(identify(
            "Code Helper (Plugin)",
            "--ms-enable-electron-run-as-node /Applications/Visual Studio Code.app/…/bootstrap-fork --type=extensionHost"
        ) == nil)
        #expect(identify("Slack Helper", "--type=renderer") == nil)
    }

    @Test("Watchers and test runners only while watching")
    func watchers() {
        #expect(identify("node", "/Users/a/app/node_modules/.bin/tsc --watch") == "tsc --watch")
        #expect(identify("node", "/Users/a/app/node_modules/.bin/tsc -p tsconfig.json") == nil)
        #expect(identify("node", "/Users/a/app/node_modules/.bin/jest --watch") == "Jest")
        #expect(identify("node", "/Users/a/app/node_modules/.bin/jest") == nil)
        #expect(identify("node", "/Users/a/app/node_modules/.bin/vitest") == "Vitest")
        #expect(identify("node", "/Users/a/app/node_modules/.bin/vitest run") == nil)
        #expect(identify("node", "/Users/a/app/node_modules/.bin/nodemon server.js") == "nodemon")
        #expect(identify("watchman") == "watchman")
        // A name inside another word isn't the tool.
        #expect(identify("node", "/Users/a/majestic/node_modules/.bin/tsc --watch") == "tsc --watch")
        #expect(identify("python3", "/Users/a/Developer/scriptwriter/app.py") == nil)
        #expect(identify("node", "/Users/a/app/node_modules/basedpyright/langserver.index.js") == "basedpyright")
        #expect(identify("node", "/Users/a/.vscode/extensions/ms-python.vscode-pylance-2025.1.1/dist/server.bundle.js") == "Pylance")
    }

    @Test("Left behind once its editor or terminal is gone; watchman never")
    func leftBehind() {
        func tool(_ name: String, parent: String?) -> DevTool {
            DevTool(
                pid: 1,
                name: name,
                kind: .languageServer,
                project: nil,
                directory: nil,
                startedAt: nil,
                memoryBytes: 0,
                cpuSeconds: 0,
                parent: parent
            )
        }
        #expect(tool("rust-analyzer", parent: nil).isLeftBehind)
        #expect(!tool("rust-analyzer", parent: "Code Helper (Plugin)").isLeftBehind)
        #expect(!tool("watchman", parent: nil).isLeftBehind)
        #expect(!tool("eslint_d", parent: nil).isLeftBehind)
    }
}
