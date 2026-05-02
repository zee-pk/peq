import Foundation

final class PresetStore {
    private let key = "peq.eq-settings.v1"
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> EQSettings {
        guard let data = defaults.data(forKey: key) else {
            return .flat
        }

        do {
            return try decoder.decode(EQSettings.self, from: data).sanitized()
        } catch {
            return .flat
        }
    }

    func save(_ settings: EQSettings) {
        do {
            let data = try encoder.encode(settings.sanitized())
            defaults.set(data, forKey: key)
        } catch {
            defaults.removeObject(forKey: key)
        }
    }
    
    func savePreset(_ settings: EQSettings, name: String) {
        do {
            let data = try encoder.encode(settings.sanitized())
            defaults.set(data, forKey: "peq.preset.\(name)")
        } catch {}
    }
    
    func loadPreset(name: String) -> EQSettings? {
        guard let data = defaults.data(forKey: "peq.preset.\(name)") else { return nil }
        return try? decoder.decode(EQSettings.self, from: data).sanitized()
    }
    
    func getSavedPresets() -> [String] {
        return defaults.dictionaryRepresentation().keys.compactMap { dictKey in
            if dictKey.hasPrefix("peq.preset.") {
                return String(dictKey.dropFirst("peq.preset.".count))
            }
            return nil
        }.sorted()
    }

    func deletePreset(name: String) {
        defaults.removeObject(forKey: "peq.preset.\(name)")
    }
}
