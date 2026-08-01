import Foundation

/// Loads input-device profiles from the app bundle and Application Support drop-in folder.
/// Drop-in files with the same `id` override bundled profiles.
final class ProfileCatalog {
    static let shared = ProfileCatalog()

    static let defaultProfileID = "lg-mr25ga"

    private(set) var profiles: [InputDeviceProfile] = []

    var dropInDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagicRemoteBLE", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
        return base
    }

    func reload() {
        var byID: [String: InputDeviceProfile] = [:]

        for url in bundleProfileURLs() {
            if let p = Self.decodeProfile(at: url) {
                byID[p.id] = p
            }
        }

        let dropIn = dropInDirectory
        try? FileManager.default.createDirectory(at: dropIn, withIntermediateDirectories: true)
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: dropIn,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in urls where url.pathExtension.lowercased() == "json" {
                if let p = Self.decodeProfile(at: url) {
                    byID[p.id] = p
                }
            }
        }

        profiles = byID.values.sorted {
            if $0.id == Self.defaultProfileID { return true }
            if $1.id == Self.defaultProfileID { return false }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func profile(id: String) -> InputDeviceProfile? {
        profiles.first { $0.id == id }
    }

    func profile(matchingBLEName name: String) -> InputDeviceProfile? {
        profiles.first { $0.matches(bleName: name) }
    }

    /// Guaranteed non-nil: prefers `id`, then default, then first loaded.
    func resolve(id: String?) -> InputDeviceProfile {
        if let id, let p = profile(id: id) { return p }
        if let p = profile(id: Self.defaultProfileID) { return p }
        if let p = profiles.first { return p }
        return Self.fallbackMR25GA
    }

    private func bundleProfileURLs() -> [URL] {
        var urls: [URL] = []
        if let builtIn = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Profiles") {
            urls.append(contentsOf: builtIn)
        }
        /* Flat copy next to resources (some Xcode setups flatten folders). */
        if let root = Bundle.main.resourceURL {
            let dir = root.appendingPathComponent("Profiles", isDirectory: true)
            if let list = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) {
                urls.append(contentsOf: list.filter { $0.pathExtension.lowercased() == "json" })
            }
        }
        /* Deduplicate by path. */
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    private static func decodeProfile(at url: URL) -> InputDeviceProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(InputDeviceProfile.self, from: data)
        } catch {
            NSLog("ProfileCatalog: failed to decode \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Hardcoded emergency fallback if no JSON is found (keeps app usable).
    private static let fallbackMR25GA: InputDeviceProfile = {
        let json = """
        {"schemaVersion":1,"id":"lg-mr25ga","displayName":"LG Magic Remote MR25GA",
        "match":{"bleNameContains":["MR25GA","LGE MR"]},
        "buttons":[{"code":"0x8044","name":"Wheel/OK","role":"ok"},
        {"code":"0x8043","name":"Settings","role":"settings"},
        {"code":"0x8028","name":"Back","role":"back"}],
        "mouseBindings":{"left":"ok","right":"settings","back":"back"},
        "defaultMaps":[{"code":"0x8044","mod":0,"key":"0x28","enabled":true}],
        "pad":{"sections":[]}}
        """
        return try! JSONDecoder().decode(InputDeviceProfile.self, from: Data(json.utf8))
    }()
}
