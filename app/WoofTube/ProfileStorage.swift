import Foundation

/// Where each account keeps its downloads and watch positions, as in Woof Music.
/// The first account keeps the app's original paths, so its data never moves.
enum ProfileStorage {
    /// The original paths. Other accounts use a UUID.
    static let original = ""

    private static let activeKey = "profile.activeStorage"
    private static let ownersKey = "profile.storageOwners"

    static var active: String {
        UserDefaults.standard.string(forKey: activeKey) ?? original
    }

    static func activate(_ storage: String) {
        UserDefaults.standard.set(storage, forKey: activeKey)
    }

    /// The account's storage. It stays reserved after a sign-out, so signing
    /// back in finds the same downloads and positions.
    static func claim(for accountId: String) -> String {
        selfCheck()
        var owners = UserDefaults.standard.dictionary(forKey: ownersKey) as? [String: String] ?? [:]
        let storage = storage(for: accountId, owners: owners, active: active, newStorage: UUID().uuidString)
        owners[accountId] = storage
        UserDefaults.standard.set(owners, forKey: ownersKey)
        return storage
    }

    /// A new account takes the active storage if no account owns it: that is
    /// the data of the app before its first sign-in.
    private static func storage(for accountId: String, owners: [String: String], active: String, newStorage: String) -> String {
        if let owned = owners[accountId] { return owned }
        return owners.values.contains(active) ? newStorage : active
    }

    static var downloadsFolder: URL {
        guard active != original else { return URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory) }
        return URL.documentsDirectory.appending(path: "Profiles/\(active)/Downloads", directoryHint: .isDirectory)
    }

    static var defaults: UserDefaults {
        guard active != original else { return .standard }
        return UserDefaults(suiteName: "profile.\(active)") ?? .standard
    }

    private static func selfCheck() {
        assert(storage(for: "a", owners: [:], active: original, newStorage: "new") == original)
        assert(storage(for: "b", owners: ["a": original], active: original, newStorage: "new") == "new")
        assert(storage(for: "a", owners: ["a": original, "b": "new"], active: "new", newStorage: "other") == original)
    }
}
