// `mactivity`: the read-only command-line tool (expansion E6). Usage is in Help.swift.
import Foundation

await exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
