import Foundation
import Network

extension LinkNode {
    private static let queue = DispatchQueue(label: "app.imp.link.node")

    // MARK: Start and stop

    /// Starts listening, advertising and dialling. Returns once the listener is up (or failed to be:
    /// a problem is reported then). An iPhone calls this when the app comes to the front.
    public func start() async {
        guard !running else { return }
        running = true
        callHomeUnanswered()
        let (stream, continuation) = AsyncStream.makeStream(of: Note.self)
        notes = continuation
        noteTask = Task { @MainActor [weak self] in
            for await note in stream { self?.handle(note) }
        }
        let ready = Once<UInt16?>()
        listening = ready
        startListener(fixed: options.port)
        if options.bonjour { startBrowser() }
        if options.watchesNetwork { startMonitor() }
        housekeeping = Task { @MainActor [weak self] in
            while let tick = self?.options.tick, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tick))
                self?.tick()
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            ready.fulfil(nil)
        }
        reconcile()
        _ = await ready.wait()
    }

    /// Throws of our own Imps that were in the air when this device last stopped, and never got an
    /// answer: the Imp is called home, so a receiver that did take it hears `gone` when it claims.
    private func callHomeUnanswered() {
        let lost = book.passing.filter { transfers.outgoing[$0.transfer] == nil }
        guard !lost.isEmpty else { return }
        book.passing.removeAll { p in lost.contains(p) }
        for p in lost where book.away.holder(of: p.imp) == p.to { book.away.callHome(p.imp) }
        commit()
    }

    /// Stops everything and closes every connection. An iPhone calls this when the app leaves the front.
    public func stop() {
        guard running else { return }
        running = false
        housekeeping?.cancel()
        housekeeping = nil
        noteTask?.cancel()
        noteTask = nil
        notes?.finish()
        notes = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        monitor?.cancel()
        monitor = nil
        hopHost?.stop()
        hopHost = nil
        for dial in dials.values { dial.cancelled = true; dial.wake?.fulfil(()) }
        dials = [:]
        for session in sessions { retire(session) }
        for join in joins.values { join.result.fulfil(.failure(.notRunning)) }
        listening?.fulfil(nil)
        listening = nil
        port = nil
        found = [:]
        arrivals = [:]
    }

    // MARK: Listener

    func startListener(fixed: UInt16?) {
        guard let notes else { return }
        listener?.cancel()
        listener = nil
        listenerGeneration += 1
        let generation = listenerGeneration
        do {
            let params = LinkCrypto.parameters(door: book.door)
            let l: NWListener
            if let fixed, let number = NWEndpoint.Port(rawValue: fixed) { l = try NWListener(using: params, on: number) } else { l = try NWListener(using: params) }
            if options.bonjour {
                let me = identity.id.uuidString
                l.service = NWListener.Service(name: me, type: LinkProtocol.serviceType, txtRecord: NWTXTRecord(["d": me]))
            }
            l.newConnectionHandler = { notes.yield(.accepted($0)) }
            l.stateUpdateHandler = { [weak l] state in
                switch state {
                case .ready:
                    if let port = l?.port?.rawValue { notes.yield(.listening(generation: generation, port: port)) }
                case .failed(let error):
                    notes.yield(.listenerFailed(generation: generation, error.localizedDescription))
                default: break
                }
            }
            triedFixedPort = fixed != nil
            l.start(queue: Self.queue)
            listener = l
        } catch {
            if fixed != nil { startListener(fixed: nil) } else { listenerFailed(error.localizedDescription) }
        }
    }

    private func listenerFailed(_ description: String) {
        emit(.problem(.listener(description)))
        listening?.fulfil(nil)
    }

    private func startBrowser() {
        guard let notes else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: LinkProtocol.serviceType, domain: nil), using: params)
        let me = identity.id
        b.browseResultsChangedHandler = { results, _ in
            var map: [UUID: NWEndpoint] = [:]
            for result in results {
                if case .bonjour(let txt) = result.metadata, let d = txt["d"], let id = UUID(uuidString: d), id != me { map[id] = result.endpoint }
            }
            notes.yield(.found(map))
        }
        b.start(queue: Self.queue)
        browser = b
    }

    private func startMonitor() {
        guard let notes else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { _ in notes.yield(.path) }
        m.start(queue: Self.queue)
        monitor = m
    }

    func restartHop() {
        hopHost?.stop()
        hopHost = nil
        guard running, let hop, let port else { return }
        let host = HopHost(address: hop, credentials: Hop.Credentials(host: identity, door: book.door), loopbackPort: port)
        host.onRejected = { [weak self] in Task { @MainActor in self?.emit(.problem(.hop)) } }
        host.start()
        hopHost = host
    }

    // MARK: What the network says

    func handle(_ note: Note) {
        guard running else {
            if case .accepted(let connection) = note { connection.cancel() }
            return
        }
        switch note {
        case .accepted(let connection):
            guard sessions.count < LinkProtocol.maxConnections else {
                emit(.problem(.full("connections")))
                return connection.cancel()
            }
            _ = open(LinkChannel(connection: connection, pingInterval: options.pingInterval, silenceLimit: options.silenceLimit), target: nil)
        case .listening(let generation, let number):
            guard generation == listenerGeneration else { return }
            port = number
            listening?.fulfil(number)
            restartHop()
            publishRoutes()
        case .listenerFailed(let generation, let description):
            guard generation == listenerGeneration else { return }
            // The fixed port was taken: any other will do (Bonjour and routes tell the way).
            if triedFixedPort { startListener(fixed: nil) } else { listenerFailed(description) }
        case .found(let map):
            found = map
            kick(Array(map.keys))
        case .path:
            if options.hosts == nil {
                let now = Self.localHosts()
                if now != hosts { hosts = now; publishRoutes() }
            }
            hopHost?.retryNow()
            kick(nil)
        }
    }

    /// Dials again now: a device was found, or the network changed.
    private func kick(_ devices: [UUID]?) {
        for id in devices ?? Array(dials.keys) {
            delays[id] = nil
            dials[id]?.wake?.fulfil(())
        }
        reconcile()
    }

    // MARK: Time

    func tick() {
        guard running else { return }
        let now = Date()
        for t in transfers.expired(now: now) { finishPass(t, .declined(.timeout)) }
        for lapsed in transfers.lapsed(now: now) { arrivals[lapsed.id] = nil }
        // Nothing stays that no longer waits for the app.
        for id in arrivals.keys where !transfers.isWaiting(id) { arrivals[id] = nil }
        for q in talks.expired(now: now) { fail(q) }
        for session in sessions {
            if let deadline = session.handshakeDeadline, now > deadline { retire(session) }
            if let grace = session.graceDeadline, now > grace { retire(session) }
        }
        book.visits.expire(now: now)
    }

    // MARK: Dialling

    /// Every device this one wants a connection to: its links (whose door key it knows), the homes of
    /// the Imps it holds or sent home, and the host of a code being scanned.
    private func wanted() -> [UUID: DialTarget] {
        var targets: [UUID: DialTarget] = [:]
        for home in book.visits.homes { targets[home.id] = DialTarget(card: home) }
        for link in book.links { if let card = link.card { targets[link.id] = DialTarget(card: card) } }
        for (id, join) in joins { targets[id] = DialTarget(card: join.invite.card, join: join.invite.invite) }
        targets[identity.id] = nil
        return targets
    }

    /// Starts dialling whatever is wanted and isn't connected or being dialled, and stops dialling what isn't wanted.
    func reconcile() {
        guard running else { return }
        let targets = wanted()
        for (id, dial) in dials where targets[id] == nil {
            dial.cancelled = true
            dial.wake?.fulfil(())
            dials[id] = nil
        }
        for id in targets.keys where connections[id] == nil && dials[id] == nil { startDial(id) }
    }

    private func startDial(_ id: UUID) {
        let dial = Dial()
        dials[id] = dial
        Task { @MainActor [weak self, dial] in
            guard let self else { return }
            defer { if self.dials[id] === dial { self.dials[id] = nil } }
            while self.running, !dial.cancelled {
                if let wait = self.delays[id], wait > 0 {
                    let wake = Once<Void>()
                    dial.wake = wake
                    Task { try? await Task.sleep(for: .seconds(wait)); wake.fulfil(()) }
                    await wake.wait()
                    dial.wake = nil
                }
                guard self.running, !dial.cancelled, self.connections[id] == nil, let target = self.wanted()[id] else { return }
                switch await self.attempt(target, dial) {
                case .connected:
                    return
                case .failed(let refused):
                    if refused, self.reported.insert(id).inserted { self.emit(.problem(.refused(id))) }
                    if let join = self.joins[id] {
                        join.result.fulfil(.failure(refused ? .refused : .unreachable))
                        return
                    }
                    self.delays[id] = min(max((self.delays[id] ?? 0) * 2, self.options.retryStart), self.options.retryLongest)
                }
            }
        }
    }

    private enum Attempt {
        case connected
        /// Every route failed; `refused` if one answered and turned us away.
        case failed(refused: Bool)
    }

    private enum Route {
        case endpoint(NWEndpoint)
        case hop(HopAddress)
    }

    /// One round over the routes to a device: Bonjour first, then its host names, the Hop last.
    private func attempt(_ target: DialTarget, _ dial: Dial) async -> Attempt {
        var routes: [Route] = []
        if let endpoint = found[target.id] { routes.append(.endpoint(endpoint)) }
        if let port = NWEndpoint.Port(rawValue: target.card.routes.port) {
            routes += target.card.routes.hosts.map { .endpoint(.hostPort(host: NWEndpoint.Host($0), port: port)) }
        }
        if let hop = target.card.routes.hopAddress { routes.append(.hop(hop)) }
        var refused = false
        for route in routes {
            guard running, !dial.cancelled else { return .failed(refused: refused) }
            if connections[target.id] != nil { return .connected }
            let channel: LinkChannel?
            switch route {
            case .endpoint(let endpoint):
                channel = LinkChannel(to: endpoint, door: target.card.door, pingInterval: options.pingInterval, silenceLimit: options.silenceLimit)
            case .hop(let address):
                channel = LinkChannel(hop: address, host: target.card.device.key, door: target.card.door,
                                      pingInterval: options.pingInterval, silenceLimit: options.silenceLimit)
            }
            guard let channel else { continue }
            switch await open(channel, target: target).outcome.wait() {
            case .established, .superseded: return .connected
            case .refused: refused = true
            case .failed(.rejected): refused = true
            case .failed(.hopRefused): emit(.problem(.hop))
            case .failed: break
            }
        }
        return .failed(refused: refused)
    }
}
