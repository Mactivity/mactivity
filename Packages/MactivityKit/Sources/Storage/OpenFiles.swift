import Darwin
import Foundation

/// What running programs have open, for "is anything using this?". Only what this user's programs
/// show; other users' keep theirs to themselves.
public enum OpenFiles {
    /// Every program's own path, working folder and open files.
    public static func paths() -> [String] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else {
            return []
        }
        var found = Set<String>()
        for pid in pids.prefix(Int(bytes)) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                found.insert(String(cString: buffer))
            }
            var folder = proc_vnodepathinfo()
            let folderSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &folder, folderSize) == folderSize {
                let path = withUnsafeBytes(of: folder.pvi_cdir.vip_path) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
                if !path.isEmpty {
                    found.insert(path)
                }
            }
            found.formUnion(descriptorPaths(pid))
        }
        return Array(found)
    }

    private static func descriptorPaths(_ pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else {
            return []
        }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else {
            return []
        }
        return fds.prefix(Int(filled) / stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else {
                return nil
            }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
                return nil
            }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
            return path.isEmpty ? nil : path
        }
    }
}
