import Foundation

extension PocketService {
    /// The Brain the first run checked, as an iPhone Imp keeps it. The key is not part of it: it goes to the Keychain.
    public init(_ brain: FirstRunBrain) {
        self.init(baseURL: brain.baseURL, model: brain.model, name: brain.name)
    }
}
