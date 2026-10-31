import Foundation
import Network

extension LinkNode {
    // MARK: Sending

    /// Sends a message to a connected device. False if it isn't connected.
    @discardableResult
    public func send(_ message: LinkMessage, to device: UUID) -> Bool {
        guard let session = connections[device] else { return false }
        session.channel.send(message)
        return true
    }

    /// Sends a message and returns once the network took it, so a stream of file parts goes at the
    /// network's pace. False when the device isn't connected or the connection closed first.
    @discardableResult
    public func sendAndWait(_ message: LinkMessage, to device: UUID) async -> Bool {
        guard let session = connections[device] else { return false }
        return await session.channel.sendAndWait(message)
    }

    // MARK: Invites and links

    /// A new invite to show as a QR code. The previous one stops working.
    public func invite() -> LinkInvite {
        let key = LinkCrypto.randomKey()
        book.invite = key
        book.inviteShown = Date()
        inviteOnScreen = true
        commit()
        return LinkInvite(device: identity.device, door: book.door, invite: key, routes: currentRoutes())
    }

    /// The code is off the screen: it still works for 15 minutes.
    public func inviteHidden() {
        inviteOnScreen = false
        book.inviteShown = Date()
        commit()
    }

    /// Scans an invite: links with the device that showed it. Returns it once linked.
    public func join(_ invite: LinkInvite) async throws -> LinkDevice {
        guard running else { throw JoinError.notRunning }
        let id = invite.device.id
        guard id != identity.id else { throw JoinError.itsOwnCode }
        if let waiting = joins[id] { return try await waiting.result.wait().get() }
        if let i = book.links.firstIndex(where: { $0.id == id }) {
            guard LinkCrypto.equal(book.links[i].device.key, invite.device.key) else { throw JoinError.keyChanged }
            // Scanned again: take the newest addresses and door, and carry on.
            book.links[i].door = invite.door
            book.links[i].routes = invite.routes
            commit()
            reconcile()
            return book.links[i].device
        }
        guard book.links.count < LinkProtocol.maxLinks else { throw JoinError.full }
        let join = Join(invite)
        joins[id] = join
        let timeout = options.joinTimeout
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            join.result.fulfil(.failure(.timedOut))
        }
        reconcile()
        let result = await join.result.wait()
        joins[id] = nil
        reconcile()
        return try result.get()
    }

    /// Ends the link with a device: it hears `bye` if it is connected, our Imps it holds are called
    /// home, and the Imps visiting us whose home it is are sent home.
    @discardableResult
    public func forget(_ device: UUID) -> Forgotten {
        var result = Forgotten()
        let linked = book.links.contains { $0.id == device }
        if linked {
            result.calledHome = book.away.callHome(from: device)
            let sent = book.visits.sendHome(of: device)
            result.sentHome = sent.map(\.imp.id)
            if let session = connections[device] {
                deliverNotices()
                session.channel.goodbye(.bye(reason: Self.forgottenReason))
                retire(session)
            }
            book.away.dropNotices(for: device)
            dropLink(device)
        }
        reconcile()
        return result
    }

    /// Forgets every device and makes a new door key, so every old code and link stops working.
    @discardableResult
    public func forgetEveryone() -> Forgotten {
        var result = Forgotten()
        for link in book.links {
            let one = forget(link.id)
            result.calledHome += one.calledHome
            result.sentHome += one.sentHome
        }
        // Imps held by devices that were never linked can't reach us with the old door key either.
        for imp in book.away.entries.map(\.imp) where book.away.callHome(imp) != nil { result.calledHome.append(imp) }
        deliverNotices()
        book.door = LinkCrypto.randomKey()
        book.invite = nil
        book.inviteShown = nil
        inviteOnScreen = false
        commit()
        // Visitors that came in with the old door key have no business here any more.
        for session in sessions where session.target == nil { retire(session) }
        if running {
            startListener(fixed: options.port)
            restartHop()
        }
        return result
    }

    /// Removes a link from the book (no goodbye, no Imps moved: the callers do that).
    func dropLink(_ device: UUID) {
        book.links.removeAll { $0.id == device }
        stages[device] = nil
        commit()
    }

    // MARK: Routes and stage

    /// Sets (or clears) the Imp server this device waits at, and tells its peers where else to find it.
    public func setServer(_ address: HopAddress?) {
        guard hop != address else { return }
        hop = address
        if running { restartHop() }
        publishRoutes()
    }

    /// Says which Imps are on this device's screen; peers hear it now and when they connect.
    public func setStage(_ imps: [LinkStaged]) {
        let imps = Array(imps.prefix(64))
        guard imps != ownStage else { return }
        ownStage = imps
        for session in connections.values where session.standing == .peer { session.channel.send(.stage(imps: imps)) }
    }

    /// Tells every peer our routes if they changed since it last heard.
    func publishRoutes() {
        let routes = currentRoutes()
        for (id, session) in connections where session.standing == .peer && published[id] != routes {
            published[id] = routes
            session.channel.send(.routes(door: book.door, routes: routes))
        }
    }

    // MARK: Throwing

    /// Throws an Imp to a connected peer. Returns the transfer, or nil if the device isn't a connected
    /// peer. The answer comes as `.passed`; the app keeps the body until then. An Imp of this
    /// device gets a ticket for its holder; a visiting Imp is handed on with the ticket it has.
    @discardableResult
    public func pass(_ imp: LinkImp, entry: LinkEntry, to device: UUID) -> UUID? {
        guard let session = connections[device], session.standing == .peer else { return nil }
        var home: LinkCard?
        var ticket: Data?
        if let visit = book.visits.visit(of: imp.id) {
            if visit.home.id != device { home = visit.home; ticket = visit.ticket }
        } else {
            home = card
            ticket = book.away.mint(imp.id, to: device)
            commit()
        }
        let transfer = UUID()
        transfers.sent(transfer, imp: imp.id, to: device, timeout: options.transferTimeout)
        session.channel.send(.pass(transfer: transfer, imp: imp, entry: entry, home: home, ticket: ticket))
        return transfer
    }

    /// Moves an Imp hatched here to a connected peer for good. The answer comes as `.passed`
    /// (`took` once the other user agreed).
    @discardableResult
    public func adopt(_ imp: UUID, kit: String, secrets: LinkSecrets, entry: LinkEntry, to device: UUID) -> UUID? {
        guard let session = connections[device], session.standing == .peer else { return nil }
        let transfer = UUID()
        transfers.sent(transfer, imp: imp, to: device, kind: .adopt, timeout: options.transferTimeout)
        session.channel.send(.adopt(transfer: transfer, imp: imp, kit: kit, secrets: secrets, entry: entry))
        return transfer
    }

    /// The app takes an Imp (or an adoption) that was thrown here. False if it can't any more: it
    /// timed out, the thrower left, or there is no room.
    @discardableResult
    public func accept(_ transfer: UUID) -> Bool {
        guard let arrival = arrivals[transfer], let session = connections[arrival.from], transfers.isWaiting(transfer) else {
            arrivals[transfer] = nil
            return false
        }
        switch arrival.kind {
        case .pass(let imp, let entry, let home, let ticket):
            if let home, let ticket {
                guard book.visits.arrive(imp, entry: entry, from: arrival.from, home: home, ticket: ticket) else {
                    decline(transfer, reason: .full)
                    return false
                }
            } else {
                book.away.cameHome(imp.id)
            }
            commit()
            transfers.answer(transfer, .took)
            arrivals[transfer] = nil
            session.channel.send(.took(transfer: transfer))
            if let home {
                if let homeSession = connections[home.id] {
                    if let ticket = book.visits.visit(of: imp.id)?.ticket, LinkCrypto.equal(homeSession.remote?.key ?? Data(), home.device.key) {
                        claim(imp.id, ticket: ticket, on: homeSession)
                    }
                } else {
                    reconcile()
                }
            }
        case .adopt:
            transfers.answer(transfer, .took)
            arrivals[transfer] = nil
            session.channel.send(.adopted(transfer: transfer))
        }
        return true
    }

    /// The app turns down an Imp (or an adoption) that was thrown here; it bounces back.
    public func decline(_ transfer: UUID, reason: LinkDecline) {
        guard let arrival = arrivals.removeValue(forKey: transfer), transfers.answer(transfer, .declined(reason)) else { return }
        send(.declined(transfer: transfer, reason: reason), to: arrival.from)
    }

    /// An answer to a throw of ours came in (or the throw ran out of time).
    func answered(_ transfer: UUID, by device: UUID, _ outcome: Passed.Outcome) {
        guard let throwing = transfers.answered(transfer, by: device) else { return }
        finishPass(throwing, outcome)
    }

    func finishPass(_ t: Transfers.Outgoing, _ outcome: Passed.Outcome) {
        if t.kind == .pass {
            switch outcome {
            case .took:
                // It's gone from here; a visit's ticket went with it.
                if book.visits.leave(t.imp) != nil { commit() }
            case .declined(let reason):
                // An Imp of ours that wasn't taken is not away. If we can't tell whether it was
                // (no answer), the receiver is told to let go in case it took it after all.
                if book.visits.visit(of: t.imp) == nil {
                    if reason == .timeout { book.away.callHome(t.imp); deliverNotices() } else { book.away.cameHome(t.imp) }
                    commit()
                }
            }
        }
        emit(.passed(Passed(transfer: t.id, imp: t.imp, to: t.to, kind: t.kind, outcome: outcome)))
    }

    /// An Imp thrown here that still waits for the app's answer: the Imp, where it came from and how.
    func onPass(_ transfer: UUID, imp: LinkImp, entry: LinkEntry, home: LinkCard?, ticket: Data?, on s: Session, _ message: LinkMessage) {
        guard let from = s.remote?.id else { return }
        guard isNew(transfer, from: from, on: s, timeout: options.transferTimeout) else { return }
        if let reason = refusal(of: imp, home: home, from: s.remote!) {
            transfers.answer(transfer, .declined(reason))
            return s.channel.send(.declined(transfer: transfer, reason: reason))
        }
        arrivals[transfer] = Arrival(transfer: transfer, from: from, imp: imp.id, kind: .pass(imp: imp, entry: entry, home: home, ticket: ticket))
        emit(.message(message, from: from))
    }

    func onAdopt(_ transfer: UUID, imp: UUID, on s: Session, _ message: LinkMessage) {
        guard let from = s.remote?.id else { return }
        guard isNew(transfer, from: from, on: s, timeout: Transfers.adoptTimeout) else { return }
        arrivals[transfer] = Arrival(transfer: transfer, from: from, imp: imp, kind: .adopt)
        emit(.message(message, from: from))
    }

    /// Notes a throw that arrived. False if it was a repeat (answered again, or still waiting).
    private func isNew(_ transfer: UUID, from: UUID, on s: Session, timeout: TimeInterval) -> Bool {
        switch transfers.received(transfer, from: from, timeout: timeout) {
        case .new: return true
        case .pending: return false
        case .repeated(let reply):
            switch reply {
            case .took: s.channel.send(.took(transfer: transfer))
            case .declined(let reason): s.channel.send(.declined(transfer: transfer, reason: reason))
            case .waiting: break
            }
            return false
        }
    }

    /// Why a thrown Imp can't come in, if it can't.
    private func refusal(of imp: LinkImp, home: LinkCard?, from sender: LinkDevice) -> LinkDecline? {
        guard let home else {
            // Coming home: only its holder can bring it.
            return book.away.authorises(sender.id, for: imp.id) ? nil : .notLinked
        }
        if home.id == identity.id { return .notLinked }
        if let link = book.links.first(where: { $0.id == home.id }), !LinkCrypto.equal(link.device.key, home.device.key) { return .notLinked }
        if home.id == sender.id, !LinkCrypto.equal(home.device.key, sender.key) { return .notLinked }
        if book.visits.visit(of: imp.id) == nil && book.visits.isFull { return .full }
        return nil
    }

    // MARK: Away and visiting Imps

    /// Takes one of this device's Imps back from its holder at any time: its ticket dies and the
    /// holder is told as soon as it can be. Returns the holder, if it was away.
    @discardableResult
    public func callHome(_ imp: UUID) -> UUID? {
        let holder = book.away.callHome(imp)
        commit()
        deliverNotices()
        return holder
    }

    /// Sends a visiting Imp home from here (deleted, or its home forgotten): the body leaves now and
    /// the home hears as soon as it can be reached. False if it isn't a visitor.
    @discardableResult
    public func sendHome(_ imp: UUID) -> Bool {
        guard let visit = book.visits.sendHome(imp) else { return false }
        commit()
        if let session = connections[visit.home.id] { claimEverything(on: session) } else { reconcile() }
        return true
    }

    // MARK: Imps talking

    /// Starts a question from an Imp of this device to another (`to`, whose home is `toHome`).
    /// `holder` is where the asking Imp's body is (this device when at home). On `.here` the app
    /// answers it itself; on `.via` the answer comes back as `.message(.answer)`, or a failed one
    /// after the timeout; on `.unreachable` nothing was sent.
    public func talk(id: UUID, from: LinkImp, to: UUID, toHome: UUID, text: String, holder: UUID) -> LinkTalks.First {
        let first = LinkTalks.first(me: identity.id, targetHome: toHome, holder: holder, connected: Set(connections.keys))
        guard case .via(let device) = first else { return first }
        talks.sent(id, from: nil, to: device, timeout: options.answerTimeout)
        let question = LinkMessage.message(id: id, from: from, to: to, toHome: toHome, text: String(text.prefix(LinkProtocol.maxText)), forwarded: false)
        guard send(question, to: device) else {
            _ = talks.answered(id, by: device)
            return .unreachable
        }
        return first
    }
}
