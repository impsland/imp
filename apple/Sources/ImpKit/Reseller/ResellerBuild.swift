import Foundation
import ImpCore

/// The model service that comes with this build of the app, from the two settings the build stamps into
/// Info.plist (`ImpResellerURL`, `ImpResellerIssuanceURL`). Both empty is a manual build. Both set and valid
/// is an automatic one. Anything else, one of the two missing or an address that is no address, is a manual
/// build too, so a half-set build never shows a broken first run.
public enum ResellerBuild {
    public static let urlKey = "ImpResellerURL"
    public static let issuanceKey = "ImpResellerIssuanceURL"

    /// The settings of a bundle, or nil for a manual build.
    public static func settings(in bundle: Bundle = .main) -> ResellerSettings? {
        settings(base: bundle.object(forInfoDictionaryKey: urlKey) as? String,
                 issuance: bundle.object(forInfoDictionaryKey: issuanceKey) as? String)
    }

    /// The settings for two raw values, nil when both are empty or when they are not a valid pair.
    public static func settings(base: String?, issuance: String?) -> ResellerSettings? {
        (try? parseResellerSettings(base: base ?? "", issuance: issuance ?? "")) ?? nil
    }
}
