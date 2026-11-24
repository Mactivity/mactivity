import Core
import Foundation

/// Configuration profiles' real source (D-287): `/usr/bin/profiles`, as this user and only while
/// the card shows. It lists this user's profiles; the whole Mac's need root, which Mactivity
/// doesn't ask for.
public struct LiveProfiles: ProfilesSource {
    public init() {}

    public func read() async -> ProfilesReading? {
        async let listing = Command.output("/usr/bin/profiles", ["show", "-type", "configuration"])
        async let enrollment = Command.output("/usr/bin/profiles", ["status", "-type", "enrollment"])
        guard let profiles = await listing.flatMap(ProfilesParsing.profiles) else {
            return nil
        }
        return await ProfilesReading(profiles: profiles, enrollment: enrollment.flatMap(ProfilesParsing.enrollment))
    }
}
