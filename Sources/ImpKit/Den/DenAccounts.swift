import Foundation

/// The Den accounts of the Imps. An Imp gets one the first time it shares something, on the server
/// the user chose. Its token is kept where API keys are kept (`KeyFile`, or the Keychain when the user
/// asked for that), under the server's address and the Imp, so a token is only ever sent to the
/// server that made it, and one Imp never uses another's.
public struct DenAccounts: Sendable {
    public struct Login: Equatable, Sendable {
        public var handle: String
        public var token: String
    }

    private let file: KeyFile
    private let inKeychain: Bool

    public init(file: KeyFile = KeyFile(), inKeychain: Bool) {
        self.file = file
        self.inKeychain = inKeychain
    }

    private static let prefix = "den."

    private static func account(_ server: ImpServer, _ imp: UUID) -> String {
        let port = server.den.port.map { ":\($0)" } ?? ""
        return "\(prefix)\(server.den.host ?? "")\(port).\(imp.uuidString)"
    }

    // MARK: Keeping tokens

    /// The Imp's account on `server`, if it has one. From the Keychain the read may ask for the
    /// user's password, and a refusal throws `Keychain.AccessDenied`.
    public func login(on server: ImpServer, imp: UUID) throws -> Login? {
        let account = Self.account(server, imp)
        var stored = file.read(account)
        if inKeychain, let secret = try Keychain.read(account) { stored = secret }
        guard let stored, let colon = stored.firstIndex(of: ":") else { return nil }
        return Login(handle: String(stored[..<colon]), token: String(stored[stored.index(after: colon)...]))
    }

    @discardableResult
    public func save(_ login: Login, on server: ImpServer, imp: UUID) -> Bool {
        let account = Self.account(server, imp)
        let secret = "\(login.handle):\(login.token)"
        guard inKeychain else { return file.write(secret, account: account) }
        guard Keychain.write(secret, account: account) else { return false }
        file.write("", account: account)
        return true
    }

    /// Forgets the Imp's tokens on every server, for when the Imp is gone.
    public func forget(imp: UUID) {
        let ending = "." + imp.uuidString
        for account in Set(file.all().keys).union(Keychain.accounts(withPrefix: Self.prefix))
        where account.hasPrefix(Self.prefix) && account.hasSuffix(ending) {
            file.write("", account: account)
            Keychain.write("", account: account)
        }
    }

    // MARK: Making accounts

    /// The Imp's account, made on the spot if it has none: solves the Den's challenge, and picks a
    /// handle from its name, with a new suffix if the Den says it's taken.
    public func ensure(on server: ImpServer, imp: UUID, name: String, client: DenClient) async throws -> Login {
        if let login = try login(on: server, imp: imp) { return login }
        var attempt = 0
        while true {
            attempt += 1
            let challenge = try await client.challenge()
            let solution = try await Altcha.solve(challenge)
            let handle = Self.handle(for: name)
            do {
                let made = try await client.createAccount(handle: handle, altcha: try Altcha.payload(challenge, solution))
                let login = Login(handle: made.handle, token: made.token)
                guard save(login, on: server, imp: imp) else { throw DenError(status: 0, title: String(localized: "Imp couldn't keep the account's key safe.")) }
                return login
            } catch let error as DenError where error.isConflict && attempt < Self.attempts {
                continue
            }
        }
    }

    static let attempts = 5

    /// A handle from an Imp's name: lowercase ASCII with dashes, and a short random ending so two
    /// Imps called Pip don't fight over one name. Always 3 to 32 characters.
    public static func handle(for name: String, suffix: String = randomSuffix()) -> String {
        let base = DenName.slug(name, limit: 27)
        return (base.isEmpty ? "imp" : base) + "-" + suffix
    }

    public static func randomSuffix() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<4).map { _ in letters.randomElement()! })
    }
}
