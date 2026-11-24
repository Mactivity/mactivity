import Darwin
import Foundation

/// One folder's entries through `getattrlistbulk`: name, type, mount status, file ID, link
/// count, and allocated size for every entry in a handful of syscalls, with no `stat` per file.
struct BulkReader {
    struct Entry {
        var name = ""
        var error: UInt32 = 0
        var isDirectory = false
        var mountStatus: UInt32 = 0
        var fileID: UInt64 = 0
        var linkCount: UInt32 = 1
        var allocatedSize: UInt64 = 0
    }

    static let bufferSize = 128 * 1024

    /// A mount point, or an autofs trigger that would mount something if opened.
    static let mountFlags = UInt32(DIR_MNTSTATUS_MNTPOINT) | UInt32(DIR_MNTSTATUS_TRIGGER)

    /// Reused for every folder one worker reads.
    private let buffer: UnsafeMutableRawPointer
    private var request: attrlist

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Self.bits(ATTR_CMN_RETURNED_ATTRS) | Self.bits(ATTR_CMN_NAME) | Self.bits(ATTR_CMN_ERROR) |
            Self.bits(ATTR_CMN_OBJTYPE) | Self.bits(ATTR_CMN_FILEID)
        request.dirattr = Self.bits(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = Self.bits(ATTR_FILE_LINKCOUNT) | Self.bits(ATTR_FILE_ALLOCSIZE)
    }

    /// Frees the buffer. Call once, when the worker is done.
    func deallocate() {
        buffer.deallocate()
    }

    /// Calls `body` for every entry in the open folder `fd`. Returns errno if a read failed.
    mutating func readEntries(_ fd: Int32, _ body: (Entry) -> Void) -> Int32? {
        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, 0)
            if count < 0 {
                return errno
            }
            if count == 0 {
                return nil
            }
            var cursor = buffer
            for _ in 0 ..< count {
                let length = Int(cursor.load(as: UInt32.self))
                body(Self.parse(cursor + MemoryLayout<UInt32>.size))
                cursor += length
            }
        }
    }

    /// One packed entry. Attributes follow `ATTR_CMN_RETURNED_ATTRS` in bit order, except
    /// `ATTR_CMN_ERROR`, which comes first; only the returned ones are packed.
    static func parse(_ start: UnsafeMutableRawPointer) -> Entry {
        var entry = Entry()
        var cursor = start
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr
        if common & bits(ATTR_CMN_ERROR) != 0 {
            entry.error = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
        }
        if common & bits(ATTR_CMN_NAME) != 0 {
            let reference = cursor.loadUnaligned(as: attrreference_t.self)
            let namePointer = (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
            entry.name = String(cString: namePointer)
            cursor += MemoryLayout<attrreference_t>.size
        }
        if common & bits(ATTR_CMN_OBJTYPE) != 0 {
            entry.isDirectory = cursor.loadUnaligned(as: UInt32.self) == VDIR.rawValue
            cursor += MemoryLayout<UInt32>.size
        }
        if common & bits(ATTR_CMN_FILEID) != 0 {
            entry.fileID = cursor.loadUnaligned(as: UInt64.self)
            cursor += MemoryLayout<UInt64>.size
        }
        if returned.dirattr & bits(ATTR_DIR_MOUNTSTATUS) != 0 {
            entry.mountStatus = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
        }
        let file = returned.fileattr
        if file & bits(ATTR_FILE_LINKCOUNT) != 0 {
            entry.linkCount = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
        }
        if file & bits(ATTR_FILE_ALLOCSIZE) != 0 {
            entry.allocatedSize = UInt64(max(0, cursor.loadUnaligned(as: Int64.self)))
        }
        return entry
    }

    private static func bits(_ value: some BinaryInteger) -> attrgroup_t {
        attrgroup_t(truncatingIfNeeded: value)
    }
}

/// Firmlinks from the System volume into the Data volume (`/Users`, `/Applications`, …).
enum Firmlinks {
    /// The system-side paths, from `/usr/share/firmlinks`.
    static func read(from file: String = "/usr/share/firmlinks") -> Set<String> {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            return fallback
        }
        let paths = text.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").first.map(String.init)
        }
        .filter { $0.hasPrefix("/") }
        return paths.isEmpty ? fallback : Set(paths)
    }

    /// macOS 26's list, for when the file can't be read.
    static let fallback: Set<String> = [
        "/AppleInternal", "/Applications", "/Library", "/System/Library/Caches", "/System/Library/Assets",
        "/System/Library/PreinstalledAssets", "/System/Library/AssetsV2", "/System/Library/PreinstalledAssetsV2",
        "/System/Library/CoreServices/CoreTypes.bundle/Contents/Library", "/System/Library/Speech", "/Users", "/Volumes",
        "/cores", "/opt", "/pkg", "/private", "/usr/local", "/usr/libexec/cups", "/usr/share/snmp",
    ]
}

extension StorageCategory {
    /// Position in `allCases`, for the tally arrays.
    var index: Int {
        switch self {
        case .apps: 0
        case .documents: 1
        case .photosAndVideo: 2
        case .audio: 3
        case .archives: 4
        case .developer: 5
        case .systemAndLibrary: 6
        case .other: 7
        }
    }
}
