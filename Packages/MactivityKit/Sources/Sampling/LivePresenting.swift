import AppKit
import Core
import CoreAudio
import CoreGraphics
import CoreMediaIO

/// Presenting, a call or a recording, from public API (1.6): an input device or camera running
/// in any app, the main display mirrored, or Keynote or PowerPoint in front, full screen.
public struct LivePresenting: PresentingSource {
    static let presentationApps: Set<String> = ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint"]

    public init() {}

    public func current() async -> PresentingReason? {
        if Self.microphoneInUse() || Self.cameraInUse() {
            return .call
        }
        if CGDisplayIsInMirrorSet(CGMainDisplayID()) != 0 {
            return .mirroring
        }
        return await MainActor.run { Self.presentationInFront() } ? .presenting : nil
    }

    /// Any audio input device running in some process (`kAudioDevicePropertyDeviceIsRunningSomewhere`).
    static func microphoneInUse() -> Bool {
        audioDevices().contains { device in
            hasInput(device) && running(device, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        }
    }

    static func audioDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices
    }

    static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func running(_ device: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    /// Any camera running in some process (`kCMIODevicePropertyDeviceIsRunningSomewhere`).
    static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr else {
            return false
        }
        return devices.contains { device in
            var running = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
            )
            var value: UInt32 = 0
            var got: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &value)
            return status == noErr && value != 0
        }
    }

    /// Keynote or PowerPoint in front with a window as big as its screen: a slideshow.
    @MainActor
    static func presentationInFront() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, presentationApps.contains(id) else {
            return false
        }
        let screens = NSScreen.screens.map(\.frame.size)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else {
                return false
            }
            let size = CGSize(width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            return screens.contains { $0 == size }
        }
    }
}
