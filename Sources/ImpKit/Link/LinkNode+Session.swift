import Foundation
import Network

/// One connection of the node, from the first byte to the last: the handshake, who is on the other
/// end, and how far they are trusted.
@MainActor
final class Session: Hashable {
    enum Outcome: Sendable {
        case established
        /// Another connection to the same device won (see `LinkNode.prefers`).
        case superseded
        case failed(LinkChannel.Close)
        /// The device answered but its proof was wrong: no other route will do better.
        case refused
    }

    let channel: LinkChannel
    /// Who we dialled; nil for a connection someone made to us.
    let target: DialTarget?
    var binding: Data?
    var remote: LinkDevice?
    var standing: LinkStanding?
    var established = false
    var superseded = false
    var retired = false
    var establishedAt = Date()
    var handshakeDeadline: Date?
    /// A visitor must claim a ticket before this.
    var graceDeadline: Date?
    /// Claims sent and not answered yet (a second claim with the same ticket would be refused).
    var claiming: Set<UUID> = []
    var closeKind: LinkChannel.Close = .ended
    let outcome = Once<Outcome>()
    /// Frames this connection may still send in a burst; it refills with time.
    var tokens: Double
    var refilled = Date()

    init(channel: LinkChannel, target: DialTarget?, handshakeDeadline: Date, burst: Double) {
        self.channel = channel; self.target = target; self.handshakeDeadline = handshakeDeadline; tokens = burst
    }

    /// Takes a frame's token. False when the other side is sending faster than it may.
    func admit(rate: Double, burst: Double, now: Date = Date()) -> Bool {
        tokens = min(burst, tokens + now.timeIntervalSince(refilled) * rate)
        refilled = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    nonisolated static func == (a: Session, b: Session) -> Bool { a === b }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

extension LinkNode {
    /// What a `bye` with this reason means: the other side forgot us.
    public static let forgottenReason = "forgotten"

    // MARK: Sessions

    func open(_ channel: LinkChannel, target: DialTarget?) -> Session {
        let session = Session(channel: channel, target: target, handshakeDeadline: Date().addingTimeInterval(options.handshakeTimeout),
                          burst: options.frameBurst)
        sessions.insert(session)
        Task { @MainActor [weak self] in
            for await event in channel.events { self?.handle(event, on: session) }
        }
        channel.start()
        return session
    }

    private func handle(_ event: LinkChannel.Event, on s: Session) {
        guard !s.retired else { return }
        switch event {
        case .ready(let binding):
            s.binding = binding
            if let target = s.target { sendHello(s, to: target) }
        case .frame(let data):
            guard s.admit(rate: options.frameRate, burst: options.frameBurst) else {
                log.debug("closed a connection that sent too fast")
                return retire(s)
            }
            guard let message = LinkFrame.decode(LinkMessage.self, data), message.isSound else {
                // Whatever we can't read is ignored, except in the handshake, where it can't be right.
                if !s.established { retire(s) }
                return
            }
            if s.established { dispatch(message, on: s) } else { handshake(message, on: s) }
        case .closed(let why, let reason):
            s.closeKind = why
            if let reason { log.debug("link connection closed: \(reason, privacy: .public)") }
            retire(s)
        }
    }

    /// Closes a connection and forgets it. What it leaves behind (throws, questions) is settled here.
    func retire(_ s: Session) {
        guard !s.retired else { return }
        s.retired = true
        sessions.remove(s)
        s.channel.close()
        if let remote = s.remote, connections[remote.id] === s {
            connections[remote.id] = nil
            stages[remote.id] = nil
            published[remote.id] = nil
            for t in transfers.lost(remote.id) { finishPass(t, .declined(.timeout)) }
            for q in talks.lost(remote.id) { fail(q) }
            arrivals = arrivals.filter { $0.value.from != remote.id }
            if s.established && !s.superseded { emit(.disconnected(remote.id)) }
            // A connection that held for a while starts the next dial fresh; one that dropped at
            // once backs off like a failure.
            if Date().timeIntervalSince(s.establishedAt) > 30 { delays[remote.id] = nil } else {
                delays[remote.id] = min(max((delays[remote.id] ?? 0) * 2, options.retryStart), options.retryLongest)
            }
        }
        s.outcome.fulfil(.failed(s.closeKind))
        reconcile()
    }

    // MARK: Handshake

    private func sendHello(_ s: Session, to target: DialTarget) {
        guard let binding = s.binding else { return }
        let proof = identity.sign(LinkCrypto.helloMessage(binding: binding, host: target.id))
        let join = target.join.map { LinkCrypto.joinProof(invite: $0, binding: binding) }
        s.channel.send(.hello(device: identity.id, name: identity.name, kind: identity.kind, key: identity.publicKey,
                              version: LinkProtocol.version, proof: proof, join: join))
    }

    private func handshake(_ message: LinkMessage, on s: Session) {
        switch message {
        case .hello(let device, let name, let kind, let key, let version, let proof, let join) where s.target == nil:
            onHello(s, device: device, name: name, kind: kind, key: key, version: version, proof: proof, join: join)
        case .welcome(let device, let name, _, let version, let linked, let proof) where s.target != nil:
            onWelcome(s, device: device, name: name, version: version, linked: linked, proof: proof)
        default:
            retire(s)
        }
    }

    /// We are the host: check who is calling, decide how far to trust them, and answer.
    private func onHello(_ s: Session, device: UUID, name: String, kind: LinkKind, key: Data, version: Int, proof: Data, join: Data?) {
        guard let binding = s.binding, version >= LinkProtocol.version, device != identity.id,
              LinkIdentity.verify(proof, of: LinkCrypto.helloMessage(binding: binding, host: identity.id), key: key) else {
            emit(.problem(.badProof(device)))
            return retire(s)
        }
        let remote = LinkDevice(id: device, name: name, kind: kind, key: key)
        var standing = LinkStanding.visitor
        var newlyLinked = false
        if let i = book.links.firstIndex(where: { $0.id == device }) {
            // A device we have a link with must be the one whose key we pinned.
            guard LinkCrypto.equal(book.links[i].device.key, key) else {
                emit(.problem(.keyChanged(device)))
                return retire(s)
            }
            standing = .peer
            if book.links[i].device.name != remote.name { book.links[i].device.name = remote.name; commit() }
        } else if let known = book.visits.homeKey(of: device), !LinkCrypto.equal(known, key) {
            // Someone using the id of a home an Imp of ours visits from, with another key.
            emit(.problem(.keyChanged(device)))
            return retire(s)
        } else if let join, let invite = book.invite, inviteIsFresh(), LinkCrypto.isValidJoin(join, invite: invite, binding: binding) {
            if book.links.count < LinkProtocol.maxLinks {
                book.links.append(LinkRecord(device: remote, door: nil, routes: .none))
                commit()
                standing = .peer
                newlyLinked = true
            } else {
                emit(.problem(.full("links")))
            }
        }
        let signature = identity.sign(LinkCrypto.welcomeMessage(binding: binding, guest: device))
        s.channel.send(.welcome(device: identity.id, name: identity.name, kind: identity.kind, version: LinkProtocol.version,
                                linked: standing == .peer, proof: signature))
        establish(s, remote: remote, standing: standing, newlyLinked: newlyLinked)
    }

    /// We are the guest: the host must prove it is the device we meant, then tells us how it sees us.
    private func onWelcome(_ s: Session, device: UUID, name: String, version: Int, linked: Bool, proof: Data) {
        guard let target = s.target, let binding = s.binding, device == target.id, version >= LinkProtocol.version else { return retire(s) }
        guard LinkIdentity.verify(proof, of: LinkCrypto.welcomeMessage(binding: binding, guest: identity.id), key: target.card.device.key) else {
            emit(.problem(.keyChanged(target.id)))
            s.outcome.fulfil(.refused)
            return retire(s)
        }
        var remote = target.card.device
        remote.name = LinkDevice.cleaned(name, kind: remote.kind)
        var standing = LinkStanding.visitor
        var newlyLinked = false
        let index = book.links.firstIndex { $0.id == target.id }
        if target.join != nil {
            guard linked else {
                emit(.problem(.inviteRefused(target.id)))
                s.outcome.fulfil(.refused)
                return retire(s)
            }
            if let index {
                book.links[index].device = remote
                book.links[index].door = target.card.door
                book.links[index].routes = target.card.routes
            } else if book.links.count < LinkProtocol.maxLinks {
                book.links.append(LinkRecord(device: remote, door: target.card.door, routes: target.card.routes))
                newlyLinked = true
            } else {
                emit(.problem(.full("links")))
                s.outcome.fulfil(.refused)
                return retire(s)
            }
            commit()
            standing = .peer
        } else if let index {
            if linked {
                standing = .peer
                if book.links[index].device.name != remote.name { book.links[index].device.name = remote.name; commit() }
            } else {
                // It forgot us: so do we, but a visitor may still have business with it.
                emit(.forgotten(target.id, dropped(target.id)))
            }
        } else if linked {
            // It thinks we are linked and we don't: say so, and it forgets us too.
            s.channel.goodbye(.bye(reason: Self.forgottenReason))
            return retire(s)
        }
        establish(s, remote: remote, standing: standing, newlyLinked: newlyLinked)
    }

    /// Whether the connection to the same device that wins is `new`: the one dialled by the device
    /// with the smaller id stays. Two dialled by the same device: the newer (the older is likely dead).
    private func prefers(_ new: Session, over old: Session, remote: UUID) -> Bool {
        let newDialler = new.target != nil ? identity.id : remote
        let oldDialler = old.target != nil ? identity.id : remote
        return newDialler == oldDialler || newDialler.uuidString < oldDialler.uuidString
    }

    private func establish(_ s: Session, remote: LinkDevice, standing: LinkStanding, newlyLinked: Bool) {
        if let old = connections[remote.id] {
            if prefers(s, over: old, remote: remote.id) {
                old.superseded = true
                connections[remote.id] = nil
                retire(old)
            } else {
                s.superseded = true
                s.outcome.fulfil(.superseded)
                return retire(s)
            }
        }
        s.remote = remote
        s.standing = standing
        s.established = true
        s.establishedAt = Date()
        s.handshakeDeadline = nil
        if standing == .visitor && s.target == nil { s.graceDeadline = Date().addingTimeInterval(options.visitorGrace) }
        connections[remote.id] = s
        reported.remove(remote.id)
        s.outcome.fulfil(.established)
        if newlyLinked { emit(.linked(remote)) }
        if let join = joins[remote.id], standing == .peer { join.result.fulfil(.success(remote)) }
        emit(.connected(remote, standing))
        greet(s)
    }

    /// First things after a handshake: tell a peer where we are and what is on our screen, deliver
    /// news that was waiting, and claim what we hold from this device.
    private func greet(_ s: Session) {
        guard let remote = s.remote else { return }
        if s.standing == .peer {
            let routes = currentRoutes()
            published[remote.id] = routes
            s.channel.send(.routes(door: book.door, routes: routes))
            s.channel.send(.stage(imps: ownStage))
        }
        deliverNotices()
        claimEverything(on: s)
    }

    func inviteIsFresh(now: Date = Date()) -> Bool {
        guard book.invite != nil else { return false }
        return inviteOnScreen || now.timeIntervalSince(book.inviteShown ?? .distantPast) <= options.inviteLife
    }

    // MARK: Claims

    /// Claims every Imp held from this device, and delivers the releases waiting for it. Tickets only
    /// go to the device whose key the Imp's card has.
    func claimEverything(on s: Session) {
        guard let remote = s.remote else { return }
        for c in book.visits.claims(at: remote) { claim(c.imp, ticket: c.ticket, on: s) }
        for release in book.visits.pendingReleases(at: remote) { s.channel.send(.release(imp: release.imp, ticket: release.ticket)) }
    }

    func claim(_ imp: UUID, ticket: Data, on s: Session) {
        guard s.claiming.insert(imp).inserted else { return }
        s.channel.send(.claim(imp: imp, ticket: ticket))
    }

    /// Tells every connected device the news it was owed (an Imp of ours it no longer holds).
    func deliverNotices() {
        guard !book.away.notices.isEmpty else { return }
        for (id, s) in connections {
            let imps = book.away.takeNotices(for: id)
            imps.forEach { s.channel.send(.gone(imp: $0)) }
        }
        commit()
    }

    // MARK: Messages

    private func dispatch(_ message: LinkMessage, on s: Session) {
        guard let remote = s.remote, let standing = s.standing else { return }
        let from = remote.id
        guard LinkAccess.allows(message, from: from, standing: standing, ledger: book.away, visits: book.visits) else {
            log.debug("dropped a message that \(from, privacy: .public) may not send")
            switch message {
            case .message(let id, _, _, _, _, _):
                s.channel.send(.answer(id: id, text: Self.unreachable, failed: true))
            case .ask(let imp, _), .stop(let imp), .newChat(let imp), .felt(let imp, _), .talks(let imp):
                // It isn't theirs any more: say so rather than leave them asking.
                s.channel.send(.gone(imp: imp))
            case .file(let id, let imp, _):
                s.channel.send(.fileFailed(id: id, reason: "That file isn't available."))
                s.channel.send(.gone(imp: imp))
            default: break
            }
            return
        }
        switch message {
        case .ping: s.channel.send(.pong)
        case .pong, .hello, .welcome: break
        case .bye(let reason):
            if reason == Self.forgottenReason, book.links.contains(where: { $0.id == from }) {
                let result = dropped(from)
                retire(s)
                emit(.forgotten(from, result))
            } else {
                retire(s)
            }
        case .routes(let door, let routes):
            if let i = book.links.firstIndex(where: { $0.id == from }),
               book.links[i].door != door || book.links[i].routes != routes {
                book.links[i].door = door
                book.links[i].routes = routes
                commit()
                reconcile()
            }
        case .stage(let imps):
            stages[from] = imps
            emit(.message(message, from: from))
        case .claim(let imp, let ticket): onClaim(imp, ticket: ticket, on: s, message)
        case .release(let imp, let ticket): onRelease(imp, ticket: ticket, on: s, message)
        case .claimed(let imp, let ticket): onClaimed(imp, ticket: ticket, on: s)
        case .gone(let imp): onGone(imp, on: s, message)
        case .pass(let transfer, let imp, let entry, let home, let ticket):
            onPass(transfer, imp: imp, entry: entry, home: home, ticket: ticket, on: s, message)
        case .adopt(let transfer, let imp, _, _, _): onAdopt(transfer, imp: imp, on: s, message)
        case .took(let transfer): answered(transfer, by: from, .took)
        case .declined(let transfer, let reason): answered(transfer, by: from, .declined(reason))
        case .adopted(let transfer): answered(transfer, by: from, .took)
        case .message(let id, let imp, let to, let toHome, let text, let forwarded):
            onTalk(id, from: imp, to: to, toHome: toHome, text: text, forwarded: forwarded, on: s, message)
        case .answer(let id, let text, let failed): onAnswer(id, text: text, failed: failed, from: from, message)
        case .look(let imp):
            book.visits.update(imp)
            commit()
            emit(.message(message, from: from))
        default:
            emit(.message(message, from: from))
        }
    }

    private func onClaim(_ imp: UUID, ticket: Data, on s: Session, _ message: LinkMessage) {
        guard let from = s.remote?.id else { return }
        switch book.away.claim(imp, ticket: ticket, by: from) {
        case .granted(let fresh, _):
            s.graceDeadline = nil
            commit()
            s.channel.send(.claimed(imp: imp, ticket: fresh))
            deliverNotices()
            emit(.message(message, from: from))
        case .refused:
            s.channel.send(.gone(imp: imp))
        }
    }

    private func onRelease(_ imp: UUID, ticket: Data, on s: Session, _ message: LinkMessage) {
        guard let from = s.remote?.id else { return }
        if book.away.release(imp, ticket: ticket) {
            s.graceDeadline = nil
            commit()
            emit(.message(message, from: from))
        }
        // Either way the sender can stop trying.
        s.channel.send(.gone(imp: imp))
    }

    private func onClaimed(_ imp: UUID, ticket: Data, on s: Session) {
        guard let from = s.remote?.id else { return }
        s.claiming.remove(imp)
        if let visit = book.visits.visit(of: imp) {
            guard visit.home.id == from else { return }
            book.visits.rotate(imp, ticket: ticket)
            commit()
        } else if book.visits.rotateRelease(imp, ticket: ticket, at: from) {
            commit()
            s.channel.send(.release(imp: imp, ticket: ticket))
        } else {
            // We hold no body for it (a claim that crossed a throw): don't leave it away.
            s.channel.send(.release(imp: imp, ticket: ticket))
        }
    }

    private func onGone(_ imp: UUID, on s: Session, _ message: LinkMessage) {
        guard let from = s.remote?.id else { return }
        s.claiming.remove(imp)
        book.visits.delivered(imp, at: from)
        if book.visits.visit(of: imp)?.home.id == from {
            book.visits.leave(imp)
            commit()
            emit(.message(message, from: from))
        } else {
            commit()
        }
    }

    // MARK: Imp talk

    private func onTalk(_ id: UUID, from imp: LinkImp, to: UUID, toHome: UUID, text: String, forwarded: Bool, on s: Session, _ message: LinkMessage) {
        guard let from = s.remote?.id else { return }
        switch LinkTalks.received(me: identity.id, targetHome: toHome, forwarded: forwarded, sender: from, connected: Set(connections.keys)) {
        case .answer:
            // Only what is on the screen the target's body is on may ask it something.
            let screen = book.away.holder(of: to).map { stages[$0] ?? [] } ?? ownStage
            guard LinkTalks.mayAsk(asker: imp.id, screen: screen, forwarded: forwarded, sender: from,
                                   senderStage: stages[from] ?? [], known: ownStage + stages.values.joined()) else {
                log.debug("refused a question that \(from, privacy: .public) may not put")
                return s.channel.send(.answer(id: id, text: Self.unreachable, failed: true))
            }
            emit(.message(message, from: from))
        case .forward(let target):
            guard talks.count(from: from) < LinkTalks.perSender else {
                return s.channel.send(.answer(id: id, text: Self.busy, failed: true))
            }
            guard talks.sent(id, from: from, to: target, timeout: options.answerTimeout) else {
                return s.channel.send(.answer(id: id, text: Self.unreachable, failed: true))
            }
            let forward = LinkMessage.message(id: id, from: imp, to: to, toHome: toHome, text: text, forwarded: true)
            if !send(forward, to: target) {
                _ = talks.answered(id, by: target)
                s.channel.send(.answer(id: id, text: Self.unreachable, failed: true))
            }
        case .refuse:
            s.channel.send(.answer(id: id, text: Self.unreachable, failed: true))
        }
    }

    private func onAnswer(_ id: UUID, text: String, failed: Bool, from: UUID, _ message: LinkMessage) {
        guard let question = talks.answered(id, by: from) else { return }
        if let back = question.from {
            send(.answer(id: id, text: text, failed: failed), to: back)
        } else {
            emit(.message(message, from: from))
        }
    }

    static let unreachable = "That Imp can't be reached right now."
    static let busy = "Too many questions are waiting. Try again in a moment."

    /// A question that will never be answered: fail it the way an answer would arrive.
    func fail(_ question: LinkTalks.Pending.Question) {
        let failure = LinkMessage.answer(id: question.id, text: Self.unreachable, failed: true)
        if let back = question.from { send(failure, to: back) } else { emit(.message(failure, from: question.to)) }
    }
}
