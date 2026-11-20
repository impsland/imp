import ImpKit
@testable import Imp

extension ImpProfile {
    /// An Imp at home, for a test whose app starts with none (a fresh install has no Imp).
    static var waiting: ImpProfile {
        var p = ImpProfile.imp
        p.isActive = false
        return p
    }
}

/// Apps of tests whose Imps start work that may outlive the test (a request still recording its reply). An Imp holds
/// its app `unowned`, as in the app it never outlives it; here the app is kept for the rest of the run, so such work
/// finishes against a live app instead of crashing a later test.
@MainActor enum KeptApps {
    private static var apps: [AppModel] = []

    @discardableResult
    static func keep(_ app: AppModel) -> AppModel {
        apps.append(app)
        return app
    }
}
