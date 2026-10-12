import Foundation
import Testing
@testable import PersonalGantt

struct LocalSyncFrameTests {
    @Test func fragmentedAndCoalescedFrames() throws {
        let a = Data(repeating: 7, count: 100_000), b = Data("second".utf8)
        let wire = try LocalSyncFrame.encode(a) + LocalSyncFrame.encode(b)
        var parser = LocalSyncFrame(), received: [Data] = []
        for offset in stride(from: 0, to: wire.count, by: 17) {
            try parser.append(wire.subdata(in: offset..<min(offset + 17, wire.count))) { received.append($0) }
        }
        try parser.finish(); #expect(received == [a, b])
        var coalesced = LocalSyncFrame(), together: [Data] = []
        try coalesced.append(wire) { together.append($0) }; #expect(together == [a, b])
    }
    @Test func corruptOrUnboundedFramesNeverDeliver() throws {
        let valid = try LocalSyncFrame.encode(Data([1, 2, 3]))
        var badHash = valid; badHash[40] ^= 1
        var badVersion = valid; badVersion[3] = 2
        var oversized = valid; oversized.replaceSubrange(4..<8, with: [0x7f, 0xff, 0xff, 0xff])
        var empty = valid; empty.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        for wire in [badHash, badVersion, oversized, empty] {
            var parser = LocalSyncFrame(), delivered = false
            #expect(throws: LocalSyncError.self) { try parser.append(wire) { _ in delivered = true } }
            #expect(!delivered)
        }
        var truncated = LocalSyncFrame()
        try truncated.append(Data(valid.dropLast())) { _ in Issue.record("truncated frame delivered") }
        #expect(throws: LocalSyncError.invalidData) { try truncated.finish() }
    }
    @Test func maximumPayloadAndSplitHeader() throws {
        let data = Data(repeating: 3, count: LocalSyncConstants.maximumBytes)
        let wire = try LocalSyncFrame.encode(data)
        var parser = LocalSyncFrame(), received: Data?
        try parser.append(Data(wire.prefix(39))) { received = $0 }; #expect(received == nil)
        try parser.append(Data(wire.dropFirst(39))) { received = $0 }; #expect(received == data)
        #expect(throws: LocalSyncError.tooLarge) { try LocalSyncFrame.encode(data + Data([0])) }
    }
}

@MainActor private final class RouteProbe: LocalSyncLink {
    var onEvent: ((LocalLinkEvent) -> Void)?
    let certificateHash: Data
    var connects = 0, sends = 0, disconnects = 0
    var didStart: (() -> Void)?
    init(hash: Data = Data(repeating: 9, count: 32)) { certificateHash = hash }
    func start(pairing: Bool, trusted: LocalTrustedDevice?) throws { didStart?() }
    func updateTrust(_ trusted: LocalTrustedDevice) { }
    func stop() { }
    func connect(_ peer: LocalPeer) throws { connects += 1; onEvent?(.connecting) }
    func send(_ data: Data) throws { sends += 1 }
    func disconnect() { disconnects += 1 }
}
@MainActor struct AdaptiveLocalLinkTests {
    private let peer = LocalPeer(id: UUID(), name: "Synthetic peer", pairing: true)
    @Test func winnerSuppressesLoserFramesAndState() throws {
        let network = RouteProbe(), mpc = RouteProbe(), link = AdaptiveLocalLink(network: network, multipeer: mpc)
        var connections = 0, messages = 0, lost = 0
        link.onEvent = { event in
            if case .connected = event { connections += 1 }
            if case .received = event { messages += 1 }
            if case .disconnected = event { lost += 1 }
        }
        try link.start(pairing: true, trusted: nil)
        network.onEvent?(.found(peer)); mpc.onEvent?(.found(peer)); try link.connect(peer)
        network.onEvent?(.connected(peer, certificateHash: network.certificateHash))
        mpc.onEvent?(.connected(peer, certificateHash: network.certificateHash))
        mpc.onEvent?(.received(Data([1]))); mpc.onEvent?(.disconnected); mpc.onEvent?(.failed(.network))
        network.onEvent?(.received(Data([2]))); try link.send(Data([3]))
        #expect(connections == 1 && messages == 1 && lost == 0)
        #expect(network.sends == 1 && mpc.sends == 0 && mpc.disconnects > 0)
        link.stop()
    }
    @Test func routeFailureFallsBackImmediatelyWithoutChangingIdentity() throws {
        let network = RouteProbe(), mpc = RouteProbe(), link = AdaptiveLocalLink(network: network, multipeer: mpc)
        try link.start(pairing: true, trusted: nil)
        network.onEvent?(.found(peer)); mpc.onEvent?(.found(peer)); try link.connect(peer)
        network.onEvent?(.failed(.network))
        #expect(network.connects == 1 && mpc.connects == 1)
        mpc.onEvent?(.connected(peer, certificateHash: mpc.certificateHash)); try link.send(Data([1]))
        #expect(link.certificateHash == mpc.certificateHash && mpc.sends == 1)
        link.stop()
    }
    @Test func primaryDiscoveryCanArriveAfterButtonPress() throws {
        let network = RouteProbe(), mpc = RouteProbe(), link = AdaptiveLocalLink(network: network, multipeer: mpc)
        try link.start(pairing: true, trusted: nil)
        mpc.onEvent?(.found(peer)); try link.connect(peer); #expect(network.connects == 0 && mpc.connects == 0)
        network.onEvent?(.found(peer)); #expect(network.connects == 1 && mpc.connects == 0)
        link.stop()
    }
    @Test func mismatchedLocalIdentitiesCannotStart() {
        let link = AdaptiveLocalLink(network: RouteProbe(), multipeer: RouteProbe(hash: Data(repeating: 8, count: 32)))
        #expect(throws: LocalSyncError.untrusted) { try link.start(pairing: true, trusted: nil) }
    }
    @Test func untrustedPrimaryDoesNotDowngrade() throws {
        let network = RouteProbe(), mpc = RouteProbe(), link = AdaptiveLocalLink(network: network, multipeer: mpc)
        var denied = false; link.onEvent = { if case .failed(.untrusted) = $0 { denied = true } }
        try link.start(pairing: true, trusted: nil)
        network.onEvent?(.found(peer)); mpc.onEvent?(.found(peer)); try link.connect(peer)
        network.onEvent?(.failed(.untrusted)); #expect(denied && mpc.connects == 0)
        link.stop()
    }
    @Test func primaryMetadataAndTerminalValidationErrorArePreserved() throws {
        let network = RouteProbe(), mpc = RouteProbe(), link = AdaptiveLocalLink(network: network, multipeer: mpc)
        var visiblePeer: LocalPeer?, validationFailed = false
        link.onEvent = { event in
            if case .found(let peer) = event { visiblePeer = peer }
            if case .failed(.invalidData) = event { validationFailed = true }
        }
        try link.start(pairing: true, trusted: nil)
        network.onEvent?(.found(peer))
        mpc.onEvent?(.found(LocalPeer(id: peer.id, name: peer.name, pairing: false)))
        #expect(visiblePeer?.pairing == true)
        try link.connect(peer); network.onEvent?(.connected(peer, certificateHash: network.certificateHash))
        network.onEvent?(.failed(.invalidData)); #expect(validationFailed)
        link.stop()
    }
    @Test func stalledPrimaryFallsBackAndOverallWaitIsBounded() async throws {
        let network = RouteProbe(), mpc = RouteProbe()
        let link = AdaptiveLocalLink(network: network, multipeer: mpc, fallbackDelay: .milliseconds(5), connectionDelay: .milliseconds(50))
        try link.start(pairing: true, trusted: nil)
        let timedOut: Bool = await withCheckedContinuation { promise in
            link.onEvent = { if case .failed(.timeout) = $0 { promise.resume(returning: true) } }
            network.onEvent?(.found(peer)); mpc.onEvent?(.found(peer))
            do { try link.connect(peer) } catch { promise.resume(returning: false) }
        }
        #expect(network.connects == 1 && mpc.connects == 1 && timedOut)
        #expect(throws: LocalSyncError.offline) { try link.send(Data([1])) }
        link.stop()
    }
}

@MainActor struct LocalConnectionWaitTests {
    @Test func transientFailureRestartsDiscoveryWithSameTrust() async {
        let id = UUID(), link = RouteProbe()
        var value = LocalSyncPreferences(); value.enabled = true
        let trusted = LocalTrustedDevice(deviceID: UUID(), name: "Synthetic peer", certificateHash: Data(repeating: 8, count: 32), pairedAt: Date())
        value.trustedDevice = trusted
        let transport = LocalSyncTransport(deviceID: id, displayName: "Synthetic local", link: link,
            store: LocalPreferenceMemory(value: value), reconnectDelay: .milliseconds(5), snapshot: { [] }, apply: { _ in })
        transport.setAvailable(true)
        await withCheckedContinuation { promise in
            link.didStart = { link.didStart = nil; promise.resume() }
            link.onEvent?(.failed(.network))
        }
        #expect(transport.preferences.trustedDevice == trusted && !transport.isPairing && link.sends == 0)
        transport.setAvailable(false)
    }
    @Test func discoveryDeadlineReleasesSyncButtonWithoutSendingData() async {
        let id = UUID(), remote = UUID(), link = RouteProbe()
        var value = LocalSyncPreferences(); value.enabled = true
        value.trustedDevice = LocalTrustedDevice(deviceID: remote, name: "Synthetic peer", certificateHash: Data(repeating: 8, count: 32), pairedAt: Date())
        let transport = LocalSyncTransport(deviceID: id, displayName: "Synthetic local", link: link,
            store: LocalPreferenceMemory(value: value), connectionWaitDelay: .milliseconds(5), snapshot: { [] }, apply: { _ in Issue.record("unexpected application") })
        transport.setAvailable(true); await transport.syncNow()
        #expect(!transport.isSyncing && !transport.isConnected && link.sends == 0 && transport.status == "オフライン")
        transport.setAvailable(false)
    }
    @Test func cancellationReleasesConnectionWait() async {
        let id = UUID(), link = RouteProbe()
        var value = LocalSyncPreferences(); value.enabled = true
        value.trustedDevice = LocalTrustedDevice(deviceID: UUID(), name: "Synthetic peer", certificateHash: Data(repeating: 8, count: 32), pairedAt: Date())
        let transport = LocalSyncTransport(deviceID: id, displayName: "Synthetic local", link: link,
            store: LocalPreferenceMemory(value: value), snapshot: { [] }, apply: { _ in Issue.record("unexpected application") })
        transport.setAvailable(true)
        let request = _Concurrency.Task { @MainActor in await transport.syncNow() }
        await settle(); #expect(transport.isSyncing)
        request.cancel(); await request.value
        #expect(!transport.isSyncing && !transport.isConnected && link.sends == 0)
        transport.setAvailable(false)
    }
}
