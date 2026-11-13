import ImpCore
import Foundation
import Network

extension LinkNode {
    // MARK: Start and stop

    /// Starts listening and dialling. Returns once the listener is up (or failed, or five seconds passed).
    public func start() async {
        // Started, or being started: wait for the same start (listener up or failed, hosts set).
        if let starting { return await starting.wait() }
        guard !running else { return }
        let finished = Once<Void>()
        starting = finished
        running = true
        apply(core.start(now: now))
        let ready = Once<UInt16?>()
        listening = ready
        startListener(fixed: options.port)
        if options.bonjour { startBrowser() }
        if options.watchesNetwork { startMonitor() }
        housekeeping = Task { @MainActor [weak self] in
            while let tick = self?.options.tick, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tick))
                guard let self, self.running else { continue }
                self.apply(self.core.tick(now: self.now))
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            ready.fulfil(nil)
        }
        await refreshHosts()
        _ = await ready.wait()
        starting = nil
        finished.fulfil(())
    }

    func refreshHosts() async {
        guard options.hosts == nil else { return }
        let hosts = await Task.detached { Self.localHosts() }.value
        if running { setHosts(hosts) }
    }

    func setHosts(_ new: [String]) {
        hosts = new
        status.routes.hosts = new
        apply(core.setHosts(hosts: new))
    }

    /// Network.framework reports a Local Network denial as a waiting state with a policy-denied DNS error.
    nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }   // kDNSServiceErr_PolicyDenied
        return false
    }

    func networkWaiting(_ error: NWError) {
        guard running, Self.isPolicyDenied(error) else { return }
        status.localNetworkBlocked = true
        // No point waiting out the five seconds: it will not come up until the person allows it.
        listening?.fulfil(nil)
    }

    public func stop() {
        guard running else { return }
        apply(core.stop(now: now))
        running = false
        housekeeping?.cancel()
        housekeeping = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        monitor?.cancel()
        monitor = nil
        hopTask?.cancel()
        hopTask = nil
        for task in dials.values { task.cancel() }
        dials = [:]
        for socket in sockets.values { socket.cancel() }
        sockets = [:]
        listening?.fulfil(nil)
        listening = nil
        status.localNetworkBlocked = false
        port = nil
        found = [:]
        apply(core.setPort(port: nil))
    }

    // MARK: Listener

    func startListener(fixed: UInt16?) {
        listener?.cancel()
        listener = nil
        listenerGeneration += 1
        let generation = listenerGeneration
        do {
            let l: NWListener
            if let fixed, fixed > 0, let number = NWEndpoint.Port(rawValue: fixed) { l = try NWListener(using: .tcp, on: number) } else { l = try NWListener(using: .tcp) }
            if options.bonjour {
                let me = device.id.uuidString
                l.service = NWListener.Service(name: me, type: LinkProtocol.serviceType, txtRecord: NWTXTRecord(["d": me]))
            }
            l.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accepted(LinkSocket(connection: connection), viaHop: false) }
            }
            l.stateUpdateHandler = { [weak self, weak l] state in
                switch state {
                case .ready:
                    guard let number = l?.port?.rawValue else { return }
                    Task { @MainActor in self?.listenerReady(generation, number) }
                case .failed(let error):
                    Task { @MainActor in self?.listenerFailed(generation, error.localizedDescription) }
                case .waiting(let error):
                    Task { @MainActor in if generation == self?.listenerGeneration { self?.networkWaiting(error) } }
                default: break
                }
            }
            triedFixedPort = fixed != nil
            l.start(queue: LinkSocket.queue)
            listener = l
        } catch {
            if fixed != nil { startListener(fixed: nil) } else { apply(core.listenerFailed(reason: error.localizedDescription)); listening?.fulfil(nil) }
        }
    }

    private func listenerReady(_ generation: Int, _ number: UInt16) {
        guard running, generation == listenerGeneration else { return }
        status.localNetworkBlocked = false
        port = number
        listening?.fulfil(number)
        apply(core.setPort(port: number))
    }

    private func listenerFailed(_ generation: Int, _ description: String) {
        guard running, generation == listenerGeneration else { return }
        // The fixed port was taken: any other will do (Bonjour and routes tell the way).
        if triedFixedPort { startListener(fixed: nil) } else {
            apply(core.listenerFailed(reason: description))
            listening?.fulfil(nil)
        }
    }

    private func startBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: LinkProtocol.serviceType, domain: nil), using: params)
        let me = device.id
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var map: [UUID: NWEndpoint] = [:]
            for result in results {
                if case .bonjour(let txt) = result.metadata, let d = txt["d"], let id = UUID(uuidString: d), id != me { map[id] = result.endpoint }
            }
            Task { @MainActor in self?.foundDevices(map) }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .waiting(let error) = state { Task { @MainActor in self?.networkWaiting(error) } }
        }
        b.start(queue: LinkSocket.queue)
        browser = b
    }

    private func foundDevices(_ map: [UUID: NWEndpoint]) {
        guard running else { return }
        found = map
        if let steps = try? core.kick(devices: map.keys.map(\.uuidString), now: now) { apply(steps) }
    }

    private func startMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.pathChanged() }
        }
        m.start(queue: LinkSocket.queue)
        monitor = m
    }

    private func pathChanged() {
        guard running else { return }
        Task { await refreshHosts() }
        restartHop()
        if let steps = try? core.kick(devices: nil, now: now) { apply(steps) }
    }

    // MARK: Connections

    /// A connection came in, from the listener or through the Hop.
    func accepted(_ socket: LinkSocket, viaHop: Bool, first: Data = Data()) {
        guard running else { return socket.cancel() }
        let out = core.accepted(viaHop: viaHop, now: now)
        guard let conn = out.conn else { return socket.cancel() }
        if !viaHop { socket.accept() }
        attach(socket, conn: conn, out.steps, first: first)
    }

    /// Takes a connection the node numbered: carries out what it asked, then reads until it ends.
    private func attach(_ socket: LinkSocket, conn: UInt64, _ steps: [LinkStep], first: Data) {
        sockets[conn] = socket
        apply(steps)
        Task { @MainActor [weak self] in
            if !first.isEmpty, let self, self.sockets[conn] === socket { self.apply(self.core.received(conn: conn, data: first, now: self.now)) }
            while let data = await socket.read() {
                guard let self, self.sockets[conn] === socket else { return }
                self.apply(self.core.received(conn: conn, data: data, now: self.now))
            }
            guard let self, self.sockets[conn] === socket else { return }
            self.sockets[conn] = nil
            socket.cancel()
            self.apply(self.core.closed(conn: conn, now: self.now))
        }
    }

    // MARK: Dialling

    /// The node wants `device`: Bonjour first, then its hosts, then its Hop.
    func dial(_ id: UUID, _ card: LinkCard) {
        guard running, dials[id] == nil else { return }
        dials[id] = Task { @MainActor [weak self] in
            await self?.attempt(id, card)
            if let self, !Task.isCancelled { self.dials[id] = nil }
        }
    }

    private func attempt(_ id: UUID, _ card: LinkCard) async {
        var routes: [LinkSocket] = []
        if let endpoint = found[id] { routes.append(LinkSocket(endpoint: endpoint)) }
        routes += card.routes.hosts.compactMap { LinkSocket(host: $0, port: card.routes.port) }
        for socket in routes {
            guard running, !Task.isCancelled else { return }
            guard await socket.connect() else { continue }
            if await adopt(socket, id, viaHop: false, rest: Data()) { return }
        }
        if running, !Task.isCancelled, let hop = card.routes.hop.flatMap(HopAddress.init), let text = encode(card),
           let client = try? linkHopGuest(card: text), let socket = LinkSocket(host: hop.host, port: hop.port) {
            switch await Self.handshake(socket, client) {
            case .go(let rest):
                if await adopt(socket, id, viaHop: true, rest: rest) { return }
            case .rejected:
                apply(core.hopRejected())
            case .failed:
                socket.cancel()
            }
        }
        guard running, !Task.isCancelled else { return }
        if let steps = try? core.dialFailed(device: id.uuidString, now: now) { apply(steps) }
    }

    /// Hands a connected socket to the node. False when it is no longer wanted.
    private func adopt(_ socket: LinkSocket, _ id: UUID, viaHop: Bool, rest: Data) async -> Bool {
        guard running, let out = try? core.dialed(device: id.uuidString, viaHop: viaHop, now: now), let conn = out.conn else {
            socket.cancel()
            return false
        }
        attach(socket, conn: conn, out.steps, first: rest)
        return true
    }

    // MARK: The Hop

    enum HopResult {
        case go(rest: Data)
        case rejected
        case failed
    }

    /// Connects a socket to the Hop and speaks its handshake.
    nonisolated static func handshake(_ socket: LinkSocket, _ client: LinkHopClient) async -> HopResult {
        if await !socket.connect() { return .failed }
        socket.send(client.hello())
        while let data = await socket.read() {
            guard !data.isEmpty else { continue }
            guard let progress = try? client.feed(data: data) else { socket.cancel(); return .failed }
            if !progress.reply.isEmpty { socket.send(progress.reply) }
            switch progress.status {
            case .go?: return .go(rest: progress.rest)
            case .rejected?: socket.cancel(); return .rejected
            case .busy?, .nobody?: socket.cancel(); return .failed
            case nil: continue
            }
        }
        socket.cancel()
        return .failed
    }

    /// Waits in this device's Hop room, and hands each guest the Hop passes on to the node.
    func restartHop() {
        hopTask?.cancel()
        hopTask = nil
        guard running, core.hopHost() != nil else { return }
        hopTask = Task { @MainActor [weak self] in
            var delay: TimeInterval = 0
            while let self, self.running, !Task.isCancelled {
                guard let host = self.core.hopHost(), let address = HopAddress(host.address), let socket = LinkSocket(host: address.host, port: address.port) else { return }
                switch await Self.handshake(socket, host.client) {
                case .go(let rest):
                    delay = 0
                    self.accepted(socket, viaHop: true, first: rest)
                case .rejected:
                    self.apply(self.core.hopRejected())
                    return
                case .failed:
                    delay = self.core.hopRetryDelay(previous: delay)
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }
}
