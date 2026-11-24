import Core
import Darwin
import Foundation
import Security

/// Who made what's running (D-232): each program's signer, read once per file and version.
public protocol CodeSignatureSource: Sendable {
    /// The signer of each program at these paths; an app bundle's path for an app.
    func signers(of paths: [String]) async -> [String: Signer]
    /// Each process's program on disk.
    func executables(_ pids: [Int32]) async -> [Int32: String]
}

public actor LiveCodeSignatures: CodeSignatureSource {
    /// Path → (modification time, signer): a program is read again only once it changes.
    private var cache: [String: (modified: Int, signer: Signer)] = [:]

    public init() {}

    public func signers(of paths: [String]) async -> [String: Signer] {
        var result: [String: Signer] = [:]
        for path in Set(paths) {
            let modified = Self.modified(path)
            if let cached = cache[path], cached.modified == modified {
                result[path] = cached.signer
                continue
            }
            let signer = Self.signer(of: path)
            cache[path] = (modified, signer)
            result[path] = signer
        }
        return result
    }

    /// macOS's sealed system folders hold only Apple's own: no read needed.
    static let systemPrefixes = ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/", "/usr/lib/"]

    static func signer(of path: String) -> Signer {
        if systemPrefixes.contains(where: path.hasPrefix) {
            return .apple
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return .unknown
        }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        if status == errSecCSUnsigned {
            return .unsigned
        }
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            return .unknown
        }
        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        var leaf: String?
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certificates.first {
            var name: CFString?
            SecCertificateCopyCommonName(first, &name)
            leaf = name as String?
        }
        // `kSecCodeSignatureAdhoc`: signed with no identity.
        return Signer.from(
            platform: info[kSecCodeInfoPlatformIdentifier as String] as? Int, adHoc: flags & 0x0002 != 0, leaf: leaf,
            team: info[kSecCodeInfoTeamIdentifier as String] as? String
        )
    }

    /// When it last changed: for a bundle, its signature's resource list, which every update
    /// rewrites even when the bundle folder keeps its date (Chrome updates in place) (D-236).
    private static func modified(_ path: String) -> Int {
        var info = stat()
        let resources = path + "/Contents/_CodeSignature/CodeResources"
        if path.hasSuffix(".app"), stat(resources, &info) == 0 {
            return info.st_mtimespec.tv_sec
        }
        return stat(path, &info) == 0 ? info.st_mtimespec.tv_sec : 0
    }

    public func executables(_ pids: [Int32]) async -> [Int32: String] {
        Dictionary(
            pids.compactMap { pid in ProcessInspector.executablePath(pid).map { (pid, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

public struct SimulatedCodeSignatures: CodeSignatureSource {
    public init() {}

    public func signers(of paths: [String]) async -> [String: Signer] {
        Dictionary(paths.map { path in
            let signer: Signer = if path.hasPrefix("/System/") || path.contains("Safari") {
                .apple
            } else if path.contains("Xcode") {
                .appStore
            } else if path.contains("Chrome") {
                .developer(name: "Google LLC", team: "EQHXZ8M8AV")
            } else if path.contains("Slack") {
                .developer(name: "Slack Technologies, Inc.", team: "BQR82RBBHL")
            } else if path.hasPrefix("/opt/homebrew") || path.contains("node") {
                .adHoc
            } else {
                .developer(name: "Example Developer", team: "ABCDE12345")
            }
            return (path, signer)
        }, uniquingKeysWith: { first, _ in first })
    }

    public func executables(_ pids: [Int32]) async -> [Int32: String] {
        Dictionary(pids.map { ($0, "/opt/homebrew/bin/node") }, uniquingKeysWith: { first, _ in first })
    }
}
