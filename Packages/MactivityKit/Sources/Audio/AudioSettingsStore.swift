import Foundation
import Synchronization

/// Where `CoreAudioSource` keeps remembered per-app settings: a small JSON dictionary in UserDefaults. Nothing
/// else about audio is stored, and nothing leaves the Mac.
public struct AudioSettingsStore: Sendable {
    /// The UserDefaults key the app uses.
    public static let defaultsKey = "perAppVolumeSettings"

    let load: @Sendable () -> Data?
    let save: @Sendable (Data?) -> Void

    /// Settings under `key` in the standard defaults. `UserDefaults.standard` is thread-safe; it's looked up on
    /// each call rather than captured.
    public static func standardDefaults(key: String = defaultsKey) -> AudioSettingsStore {
        AudioSettingsStore {
            UserDefaults.standard.data(forKey: key)
        } save: { data in
            if let data {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// Kept in memory only: tests, and sources that mustn't touch the user's preferences.
    public static func inMemory(_ initial: Data? = nil) -> AudioSettingsStore {
        let box = Box(initial)
        return AudioSettingsStore {
            box.value.withLock { $0 }
        } save: { data in
            box.value.withLock { $0 = data }
        }
    }

    private final class Box: Sendable {
        let value: Mutex<Data?>

        init(_ initial: Data?) {
            value = Mutex(initial)
        }
    }
}
