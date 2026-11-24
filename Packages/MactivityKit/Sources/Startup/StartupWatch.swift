import Core
import Foundation

/// New startup items (1.5, D-231): what wasn't there at the last look. Pure: the known keys come
/// in and go out, the app keeps them.
public enum StartupWatch {
    /// One key per item, whatever folder it's in, so an item Mactivity disabled (moved to its
    /// own folder) and the user enables again isn't new.
    public static func key(_ item: StartupItem) -> String {
        "\(item.kind.rawValue):\(item.label)"
    }

    /// The active items not active at the last look, and the keys to keep: this look's active
    /// ones. So something that comes back after being removed, or that puts itself back while
    /// Mactivity holds a disabled copy (Google's updater does), is new again. The first look
    /// (`known` nil) learns what's there without calling any of it new.
    public static func additions(_ items: [StartupItem], known: Set<String>?) -> (new: [StartupItem], known: Set<String>) {
        // On, not merely there: an app's bundled helper that isn't registered (`notRegistered`,
        // or a login item in an unknown state) starts nothing, and becomes news only once it's
        // on (D-236).
        let active = items.filter { $0.location != .disabledByMactivity && $0.state == .on }
        let keys = Set(active.map(key))
        guard let known else {
            return ([], keys)
        }
        var seen = Set<String>()
        let new = active.filter { !known.contains(key($0)) && seen.insert(key($0)).inserted }
        return (new, keys)
    }

    /// Where the app keeps the keys.
    public static let defaultsKey = "startup.knownItems"

    /// The user turned it on in Mactivity: not news at the next look.
    public static func acknowledge(_ item: StartupItem, in defaults: UserDefaults = .standard) {
        guard let known = defaults.stringArray(forKey: defaultsKey) else {
            return
        }
        defaults.set((Set(known).union([key(item)])).sorted(), forKey: defaultsKey)
    }

    /// One alert per app: an installer that adds five daemons is one notification (D-236).
    public static func additions(grouping items: [StartupItem]) -> [StartupAddition] {
        var order: [String] = []
        var byName: [String: [StartupItem]] = [:]
        for item in items {
            let name = addition(item).name
            if byName[name] == nil {
                order.append(name)
            }
            byName[name, default: []].append(item)
        }
        return order.compactMap { name in
            guard let group = byName[name], let first = group.first else {
                return nil
            }
            guard group.count > 1 else {
                return addition(first)
            }
            let what = String(
                localized: "\(group.count) items that start in the background",
                bundle: .strings,
                comment: "New startup item alert: several added at once, e.g. 3 items that start in the background"
            )
            return StartupAddition(label: group.map(\.label).sorted().joined(separator: ", "), name: name, what: what)
        }
    }

    /// What the alert says about one.
    public static func addition(_ item: StartupItem) -> StartupAddition {
        let what = switch item.kind {
        case .loginItem:
            String(localized: "a login item", bundle: .strings, comment: "New startup item alert: what was added")
        case .agent:
            String(localized: "an agent that runs at login", bundle: .strings, comment: "New startup item alert: what was added")
        case .daemon:
            String(localized: "a daemon that runs at startup, as root", bundle: .strings, comment: "New startup item alert: what was added")
        case .appHelper:
            String(localized: "a helper that runs in the background", bundle: .strings, comment: "New startup item alert: what was added")
        }
        let owner = item.owner.evidence == .unknown || item.owner.evidence == .missingApp ? item.name : item.owner.name
        return StartupAddition(label: item.label, name: owner, what: what)
    }
}
