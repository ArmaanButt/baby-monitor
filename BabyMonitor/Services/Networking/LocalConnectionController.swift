import Combine
import CryptoKit
import Foundation
@preconcurrency import Network

@MainActor
final class LocalConnectionController: ObservableObject {
    @Published private(set) var mode: LocalConnectionMode = .idle
    @Published private(set) var state: LocalConnectionState = .idle
    @Published private(set) var discoveredMonitors: [DiscoveredMonitor] = []
    @Published private(set) var pairingCode: String?
    @Published private(set) var diagnostics = LocalConnectionDiagnostics()

    private nonisolated let engine: LocalConnectionEngine

    init(
        identity: DeviceIdentity = .current(),
        pairingStore: PairingSecretStoring = KeychainPairingSecretStore()
    ) {
        let engine = LocalConnectionEngine(
            identity: identity,
            pairingStore: pairingStore
        )
        self.engine = engine

        engine.eventHandler = { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                switch event {
                case .state(let state):
                    self.state = state
                case .discovered(let monitors):
                    self.discoveredMonitors = monitors
                case .diagnostics(let diagnostics):
                    self.diagnostics = diagnostics
                }
            }
        }
    }

    func startMonitor() {
        do {
            let code = try PairingSecurity.pairingCode()
            mode = .monitor
            pairingCode = code
            discoveredMonitors = []
            engine.startMonitor(pairingCode: code)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func startViewer() {
        mode = .viewer
        pairingCode = nil
        engine.startBrowsing()
    }

    func connect(to monitor: DiscoveredMonitor) {
        engine.connect(to: monitor.id)
    }

    func submitPairingCode(_ code: String) {
        engine.submitPairingCode(code)
    }

    func disconnect() {
        engine.stop()
        mode = .idle
        state = .idle
        pairingCode = nil
        discoveredMonitors = []
        diagnostics = LocalConnectionDiagnostics()
    }

    func revokePairings() {
        engine.revokePairings()
        disconnect()
    }

    nonisolated func sendVideo(_ frame: EncodedVideoFrame) {
        engine.sendVideo(frame)
    }

    nonisolated func sendAudio(_ frame: AudioWireFrame) {
        engine.sendAudio(frame)
    }

    func setVideoFrameHandler(
        _ handler: (@Sendable (EncodedVideoFrame) -> Void)?
    ) {
        engine.setVideoFrameHandler(handler)
    }

    func setAudioFrameHandler(
        _ handler: (@Sendable (AudioWireFrame) -> Void)?
    ) {
        engine.setAudioFrameHandler(handler)
    }

    var canSendMedia: Bool {
        state.isAuthenticated
    }
}

private nonisolated final class LocalConnectionEngine: @unchecked Sendable {
    enum Event {
        case state(LocalConnectionState)
        case discovered([DiscoveredMonitor])
        case diagnostics(LocalConnectionDiagnostics)
    }

    static let serviceType = "_babymonitor._tcp"

    var eventHandler: (@Sendable (Event) -> Void)?

    private let identity: DeviceIdentity
    private let pairingStore: PairingSecretStoring
    private let queue = DispatchQueue(
        label: "com.armaanbutt.BabyMonitor.local-network",
        qos: .userInitiated
    )
    private let outboundVideoCapacity = DispatchSemaphore(value: 2)
    private let outboundAudioCapacity = DispatchSemaphore(value: 4)

    private var mode: LocalConnectionMode = .idle
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var activeConnection: NWConnection?
    private var discoveredEndpoints: [String: NWEndpoint] = [:]
    private var selectedViewerEndpoint: NWEndpoint?
    private var shouldMaintainViewerConnection = false
    private var reconnectAttempt = 0
    private var reconnectToken: UUID?
    private var framer = WirePacketFramer()
    private var pairingCode = ""
    private var pendingViewerHello: ViewerHello?
    private var pendingMonitorPairing: MonitorPairing?
    private var pendingViewerPairing: ViewerPairing?
    private var pendingAuthentication: AuthenticationSession?
    private var authenticatedPeer: AuthenticatedPeer?
    private var videoFrameHandler: (@Sendable (EncodedVideoFrame) -> Void)?
    private var audioFrameHandler: (@Sendable (AudioWireFrame) -> Void)?
    private var diagnostics = LocalConnectionDiagnostics()

    init(identity: DeviceIdentity, pairingStore: PairingSecretStoring) {
        self.identity = identity
        self.pairingStore = pairingStore
    }

    func startMonitor(pairingCode: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked(emitIdle: false)
            self.mode = .monitor
            self.pairingCode = pairingCode

            do {
                let listener = try NWListener(using: .tcp)
                listener.service = NWListener.Service(
                    name: self.identity.name,
                    type: Self.serviceType
                )
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                switch state {
                case .ready:
                    self.emit(.state(.advertising))
                case .waiting(let error):
                    self.emit(
                        .state(
                            .waitingForNetwork(error.localizedDescription)
                        )
                    )
                case .failed(let error):
                    self.emit(.state(.failed(error.localizedDescription)))
                    self.stopLocked(emitIdle: false)
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                self.emit(.state(.failed(error.localizedDescription)))
            }
        }
    }

    func startBrowsing() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked(emitIdle: false)
            self.mode = .viewer

            let browser = NWBrowser(
                for: .bonjour(type: Self.serviceType, domain: nil),
                using: .tcp
            )
            browser.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.emit(.state(.browsing))
                case .waiting(let error):
                    self.emit(
                        .state(
                            .waitingForNetwork(error.localizedDescription)
                        )
                    )
                case .failed(let error):
                    self.emit(.state(.failed(error.localizedDescription)))
                    self.stopLocked(emitIdle: false)
                case .cancelled:
                    break
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.updateDiscoveredMonitors(results)
            }
            self.browser = browser
            browser.start(queue: self.queue)
        }
    }

    func connect(to monitorID: String) {
        queue.async { [weak self] in
            guard
                let self,
                self.mode == .viewer,
                let endpoint = self.discoveredEndpoints[monitorID]
            else {
                return
            }

            self.browser?.cancel()
            self.browser = nil
            self.selectedViewerEndpoint = endpoint
            self.shouldMaintainViewerConnection = true
            self.reconnectAttempt = 0
            self.reconnectToken = nil
            self.emit(.state(.connecting))
            self.prepareConnection(NWConnection(to: endpoint, using: .tcp))
        }
    }

    func submitPairingCode(_ code: String) {
        queue.async { [weak self] in
            guard
                let self,
                let pending = self.pendingViewerPairing,
                code.count == 6
            else {
                return
            }

            do {
                let key = try PairingSecurity.derivePairingKey(
                    privateKey: pending.privateKey,
                    peerPublicKeyData: pending.serverPublicKey,
                    clientNonce: pending.clientNonce,
                    serverNonce: pending.serverNonce,
                    code: code
                )
                let transcript = PairingSecurity.pairingTranscript(
                    clientNonce: pending.clientNonce,
                    serverNonce: pending.serverNonce,
                    clientPublicKey: pending.clientPublicKey,
                    serverPublicKey: pending.serverPublicKey
                )
                let proof = PairingSecurity.authenticationCode(
                    for: transcript,
                    key: key
                )
                self.pendingViewerPairing?.pairingKey = key
                try self.sendControl(
                    ControlMessage(kind: .pairingProof, proof: proof)
                )
                self.emit(.state(.authenticating))
            } catch {
                self.failProtocol(error)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked(emitIdle: true)
        }
    }

    func revokePairings() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.activeConnection != nil {
                try? self.sendControl(ControlMessage(kind: .revoked))
            }
            self.pairingStore.removeAll()
            self.stopLocked(emitIdle: true)
        }
    }

    func setVideoFrameHandler(
        _ handler: (@Sendable (EncodedVideoFrame) -> Void)?
    ) {
        queue.async { [weak self] in
            self?.videoFrameHandler = handler
        }
    }

    func setAudioFrameHandler(
        _ handler: (@Sendable (AudioWireFrame) -> Void)?
    ) {
        queue.async { [weak self] in
            self?.audioFrameHandler = handler
        }
    }

    func sendVideo(_ frame: EncodedVideoFrame) {
        guard outboundVideoCapacity.wait(timeout: .now()) == .success else {
            queue.async { [weak self] in
                guard let self else { return }
                self.diagnostics.droppedVideoFrames += 1
                self.emit(.diagnostics(self.diagnostics))
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard
                let authenticatedPeer = self.authenticatedPeer,
                let activeConnection = self.activeConnection
            else {
                self.outboundVideoCapacity.signal()
                return
            }

            do {
                let videoPayload = try VideoWireCodec.encode(frame)
                let payload = try PairingSecurity.encryptMedia(
                    videoPayload,
                    type: .video,
                    key: authenticatedPeer.mediaKey
                )
                let encoded = try WirePacketCodec.encode(
                    WirePacket(type: .video, payload: payload)
                )
                self.diagnostics.outboundVideoDepth += 1
                activeConnection.send(
                    content: encoded,
                    completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        self.outboundVideoCapacity.signal()
                        self.queue.async {
                            self.diagnostics.outboundVideoDepth = max(
                                0,
                                self.diagnostics.outboundVideoDepth - 1
                            )
                            if error == nil {
                                self.diagnostics.sentVideoFrames += 1
                            } else {
                                self.diagnostics.droppedVideoFrames += 1
                            }
                            self.emit(.diagnostics(self.diagnostics))
                        }
                    }
                )
            } catch {
                self.outboundVideoCapacity.signal()
                self.diagnostics.droppedVideoFrames += 1
                self.emit(.diagnostics(self.diagnostics))
            }
        }
    }

    func sendAudio(_ frame: AudioWireFrame) {
        guard outboundAudioCapacity.wait(timeout: .now()) == .success else {
            queue.async { [weak self] in
                guard let self else { return }
                self.diagnostics.droppedAudioPackets += 1
                self.emit(.diagnostics(self.diagnostics))
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard
                let authenticatedPeer = self.authenticatedPeer,
                let activeConnection = self.activeConnection
            else {
                self.outboundAudioCapacity.signal()
                return
            }

            do {
                let audioPayload = try AudioWireCodec.encode(frame)
                let payload = try PairingSecurity.encryptMedia(
                    audioPayload,
                    type: .audio,
                    key: authenticatedPeer.mediaKey
                )
                let encoded = try WirePacketCodec.encode(
                    WirePacket(type: .audio, payload: payload)
                )
                self.diagnostics.outboundAudioDepth += 1
                activeConnection.send(
                    content: encoded,
                    completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        self.outboundAudioCapacity.signal()
                        self.queue.async {
                            self.diagnostics.outboundAudioDepth = max(
                                0,
                                self.diagnostics.outboundAudioDepth - 1
                            )
                            if error == nil {
                                self.diagnostics.sentAudioPackets += 1
                            } else {
                                self.diagnostics.droppedAudioPackets += 1
                            }
                            self.emit(.diagnostics(self.diagnostics))
                        }
                    }
                )
            } catch {
                self.outboundAudioCapacity.signal()
                self.diagnostics.droppedAudioPackets += 1
                self.emit(.diagnostics(self.diagnostics))
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard mode == .monitor else {
            connection.cancel()
            return
        }
        activeConnection?.cancel()
        authenticatedPeer = nil
        diagnostics.authenticatedPeerCount = 0
        prepareConnection(connection)
    }

    private func prepareConnection(_ connection: NWConnection) {
        activeConnection?.cancel()
        activeConnection = connection
        framer = WirePacketFramer()
        pendingViewerHello = nil
        pendingMonitorPairing = nil
        pendingViewerPairing = nil
        pendingAuthentication = nil
        authenticatedPeer = nil
        diagnostics.authenticatedPeerCount = 0
        emit(.diagnostics(diagnostics))

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                guard self.activeConnection === connection else { return }
                self.reconnectToken = nil
                self.receiveNext(on: connection)
                if self.mode == .viewer {
                    do {
                        try self.sendClientHello()
                    } catch {
                        self.failProtocol(error)
                    }
                }
            case .waiting(let error):
                guard self.activeConnection === connection else { return }
                self.emit(
                    .state(.waitingForNetwork(error.localizedDescription))
                )
            case .failed(let error):
                self.handleConnectionLoss(
                    connection,
                    error: error
                )
            case .cancelled:
                self.handleConnectionLoss(connection, error: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendClientHello() throws {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientNonce = try PairingSecurity.randomData(count: 32)
        pendingViewerHello = ViewerHello(
            privateKey: privateKey,
            clientNonce: clientNonce
        )

        try sendControl(
            ControlMessage(
                kind: .clientHello,
                peerID: identity.id,
                peerName: identity.name,
                clientNonce: clientNonce,
                clientPublicKey: privateKey.publicKey.rawRepresentation
            )
        )
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self, weak connection] content, _, isComplete, error in
            guard let self, let connection else { return }

            do {
                if let content, !content.isEmpty {
                    let packets = try self.framer.append(content)
                    for packet in packets {
                        try self.handle(packet)
                    }
                }
            } catch {
                self.failProtocol(error)
                return
            }

            if let error {
                self.handleConnectionLoss(
                    connection,
                    error: error
                )
            } else if isComplete {
                self.handleConnectionLoss(connection, error: nil)
            } else {
                self.receiveNext(on: connection)
            }
        }
    }

    private func handle(_ packet: WirePacket) throws {
        guard packet.type == .control else {
            guard let authenticatedPeer else {
                diagnostics.rejectedMediaPackets += 1
                emit(.diagnostics(diagnostics))
                throw LocalConnectionError.authenticationFailed
            }

            switch packet.type {
            case .video:
                guard mode == .viewer else { return }
                do {
                    let decrypted = try PairingSecurity.decryptMedia(
                        packet.payload,
                        type: .video,
                        key: authenticatedPeer.mediaKey
                    )
                    let frame = try VideoWireCodec.decode(decrypted)
                    diagnostics.receivedVideoFrames += 1
                    emit(.diagnostics(diagnostics))
                    videoFrameHandler?(frame)
                } catch {
                    diagnostics.rejectedMediaPackets += 1
                    emit(.diagnostics(diagnostics))
                    throw error
                }
            case .audio:
                guard mode == .viewer else { return }
                do {
                    let decrypted = try PairingSecurity.decryptMedia(
                        packet.payload,
                        type: .audio,
                        key: authenticatedPeer.mediaKey
                    )
                    let frame = try AudioWireCodec.decode(decrypted)
                    diagnostics.receivedAudioPackets += 1
                    emit(.diagnostics(diagnostics))
                    audioFrameHandler?(frame)
                } catch {
                    diagnostics.rejectedMediaPackets += 1
                    emit(.diagnostics(diagnostics))
                    throw error
                }
            case .control:
                break
            }
            return
        }

        let message = try ControlMessageCodec.decode(packet.payload)
        switch mode {
        case .monitor:
            try handleMonitor(message)
        case .viewer:
            try handleViewer(message)
        case .idle:
            break
        }
    }

    private func handleMonitor(_ message: ControlMessage) throws {
        switch message.kind {
        case .clientHello:
            guard
                let viewerID = message.peerID,
                let viewerName = message.peerName,
                let clientNonce = message.clientNonce,
                let clientPublicKey = message.clientPublicKey
            else {
                throw WireProtocolError.invalidControlMessage
            }

            if let pairingSecret = pairingStore.secret(for: viewerID) {
                let serverNonce = try PairingSecurity.randomData(count: 32)
                let proof = PairingSecurity.sessionProof(
                    role: "server",
                    clientNonce: clientNonce,
                    serverNonce: serverNonce,
                    pairingSecret: pairingSecret
                )
                pendingAuthentication = AuthenticationSession(
                    peerID: viewerID,
                    peerName: viewerName,
                    clientNonce: clientNonce,
                    serverNonce: serverNonce,
                    pairingSecret: pairingSecret
                )
                try sendControl(
                    ControlMessage(
                        kind: .authenticationChallenge,
                        peerID: identity.id,
                        peerName: identity.name,
                        serverNonce: serverNonce,
                        proof: proof
                    )
                )
                emit(.state(.authenticating))
            } else {
                let privateKey = Curve25519.KeyAgreement.PrivateKey()
                let serverNonce = try PairingSecurity.randomData(count: 32)
                pendingMonitorPairing = MonitorPairing(
                    privateKey: privateKey,
                    viewerID: viewerID,
                    viewerName: viewerName,
                    clientNonce: clientNonce,
                    serverNonce: serverNonce,
                    clientPublicKey: clientPublicKey
                )
                try sendControl(
                    ControlMessage(
                        kind: .pairingChallenge,
                        peerID: identity.id,
                        peerName: identity.name,
                        serverNonce: serverNonce,
                        serverPublicKey: privateKey.publicKey.rawRepresentation
                    )
                )
                emit(.state(.authenticating))
            }

        case .pairingProof:
            guard
                let pending = pendingMonitorPairing,
                let proof = message.proof
            else {
                throw WireProtocolError.invalidControlMessage
            }

            let serverPublicKey = pending.privateKey.publicKey.rawRepresentation
            let key = try PairingSecurity.derivePairingKey(
                privateKey: pending.privateKey,
                peerPublicKeyData: pending.clientPublicKey,
                clientNonce: pending.clientNonce,
                serverNonce: pending.serverNonce,
                code: pairingCode
            )
            let transcript = PairingSecurity.pairingTranscript(
                clientNonce: pending.clientNonce,
                serverNonce: pending.serverNonce,
                clientPublicKey: pending.clientPublicKey,
                serverPublicKey: serverPublicKey
            )
            guard PairingSecurity.isValidAuthenticationCode(
                proof,
                authenticating: transcript,
                key: key
            ) else {
                throw LocalConnectionError.invalidPairingCode
            }

            let pairingSecret = try PairingSecurity.randomData(count: 32)
            try pairingStore.save(secret: pairingSecret, for: pending.viewerID)
            let encryptedSecret = try PairingSecurity.encryptPairingSecret(
                pairingSecret,
                key: key
            )
            pendingAuthentication = AuthenticationSession(
                peerID: pending.viewerID,
                peerName: pending.viewerName,
                clientNonce: pending.clientNonce,
                serverNonce: pending.serverNonce,
                pairingSecret: pairingSecret
            )
            pendingMonitorPairing = nil
            try sendControl(
                ControlMessage(
                    kind: .pairingAccepted,
                    peerID: identity.id,
                    peerName: identity.name,
                    encryptedPairingSecret: encryptedSecret
                )
            )

        case .authenticationResponse:
            guard
                let pending = pendingAuthentication,
                let proof = message.proof,
                PairingSecurity.isValidSessionProof(
                    proof,
                    role: "client",
                    clientNonce: pending.clientNonce,
                    serverNonce: pending.serverNonce,
                    pairingSecret: pending.pairingSecret
                )
            else {
                throw LocalConnectionError.authenticationFailed
            }
            try sendControl(ControlMessage(kind: .authenticated))
            completeAuthentication(pending)

        case .revoked:
            if let peer = authenticatedPeer {
                pairingStore.removeSecret(for: peer.id)
            }
            stopLocked(emitIdle: true)

        case .stop:
            activeConnection?.cancel()

        default:
            throw WireProtocolError.invalidControlMessage
        }
    }

    private func handleViewer(_ message: ControlMessage) throws {
        switch message.kind {
        case .pairingChallenge:
            guard
                let hello = pendingViewerHello,
                let monitorID = message.peerID,
                let monitorName = message.peerName,
                let serverNonce = message.serverNonce,
                let serverPublicKey = message.serverPublicKey
            else {
                throw WireProtocolError.invalidControlMessage
            }

            pendingViewerPairing = ViewerPairing(
                privateKey: hello.privateKey,
                monitorID: monitorID,
                monitorName: monitorName,
                clientNonce: hello.clientNonce,
                serverNonce: serverNonce,
                clientPublicKey: hello.privateKey.publicKey.rawRepresentation,
                serverPublicKey: serverPublicKey,
                pairingKey: nil
            )
            emit(.state(.awaitingPairingCode))

        case .pairingAccepted:
            guard
                let pending = pendingViewerPairing,
                let pairingKey = pending.pairingKey,
                let encryptedSecret = message.encryptedPairingSecret
            else {
                throw WireProtocolError.invalidControlMessage
            }

            let pairingSecret = try PairingSecurity.decryptPairingSecret(
                encryptedSecret,
                key: pairingKey
            )
            try pairingStore.save(
                secret: pairingSecret,
                for: pending.monitorID
            )
            pendingAuthentication = AuthenticationSession(
                peerID: pending.monitorID,
                peerName: pending.monitorName,
                clientNonce: pending.clientNonce,
                serverNonce: pending.serverNonce,
                pairingSecret: pairingSecret
            )
            let proof = PairingSecurity.sessionProof(
                role: "client",
                clientNonce: pending.clientNonce,
                serverNonce: pending.serverNonce,
                pairingSecret: pairingSecret
            )
            try sendControl(
                ControlMessage(kind: .authenticationResponse, proof: proof)
            )

        case .authenticationChallenge:
            guard
                let hello = pendingViewerHello,
                let monitorID = message.peerID,
                let monitorName = message.peerName,
                let serverNonce = message.serverNonce,
                let serverProof = message.proof
            else {
                throw WireProtocolError.invalidControlMessage
            }
            guard let pairingSecret = pairingStore.secret(for: monitorID) else {
                throw LocalConnectionError.authenticationFailed
            }
            guard PairingSecurity.isValidSessionProof(
                serverProof,
                role: "server",
                clientNonce: hello.clientNonce,
                serverNonce: serverNonce,
                pairingSecret: pairingSecret
            ) else {
                pairingStore.removeSecret(for: monitorID)
                throw LocalConnectionError.authenticationFailed
            }

            pendingAuthentication = AuthenticationSession(
                peerID: monitorID,
                peerName: monitorName,
                clientNonce: hello.clientNonce,
                serverNonce: serverNonce,
                pairingSecret: pairingSecret
            )
            let clientProof = PairingSecurity.sessionProof(
                role: "client",
                clientNonce: hello.clientNonce,
                serverNonce: serverNonce,
                pairingSecret: pairingSecret
            )
            try sendControl(
                ControlMessage(
                    kind: .authenticationResponse,
                    proof: clientProof
                )
            )
            emit(.state(.authenticating))

        case .authenticated:
            guard let pending = pendingAuthentication else {
                throw WireProtocolError.invalidControlMessage
            }
            completeAuthentication(pending)

        case .revoked:
            if let pending = pendingAuthentication {
                pairingStore.removeSecret(for: pending.peerID)
            } else if let peer = authenticatedPeer {
                pairingStore.removeSecret(for: peer.id)
            }
            stopLocked(emitIdle: true)

        case .stop:
            activeConnection?.cancel()

        default:
            throw WireProtocolError.invalidControlMessage
        }
    }

    private func completeAuthentication(_ session: AuthenticationSession) {
        authenticatedPeer = AuthenticatedPeer(
            id: session.peerID,
            name: session.peerName,
            mediaKey: PairingSecurity.mediaSessionKey(
                pairingSecret: session.pairingSecret,
                clientNonce: session.clientNonce,
                serverNonce: session.serverNonce
            )
        )
        pendingViewerHello = nil
        pendingViewerPairing = nil
        pendingMonitorPairing = nil
        pendingAuthentication = nil
        reconnectAttempt = 0
        reconnectToken = nil
        diagnostics.authenticatedPeerCount = 1
        emit(.diagnostics(diagnostics))
        emit(.state(.authenticated(peerName: session.peerName)))
    }

    private func sendControl(_ message: ControlMessage) throws {
        guard let activeConnection else {
            throw LocalConnectionError.notConnected
        }
        activeConnection.send(
            content: try ControlMessageCodec.encode(message),
            completion: .contentProcessed { [weak self, weak activeConnection] error in
                if let error {
                    self?.queue.async {
                        guard let self, let activeConnection else { return }
                        self.handleConnectionLoss(
                            activeConnection,
                            error: error
                        )
                    }
                }
            }
        )
    }

    private func updateDiscoveredMonitors(
        _ results: Set<NWBrowser.Result>
    ) {
        var monitors: [DiscoveredMonitor] = []
        var endpoints: [String: NWEndpoint] = [:]

        for result in results {
            let id = String(describing: result.endpoint)
            let name: String
            if case .service(let serviceName, _, _, _) = result.endpoint {
                name = serviceName
            } else {
                name = "Baby Monitor"
            }
            endpoints[id] = result.endpoint
            monitors.append(DiscoveredMonitor(id: id, name: name))
        }

        discoveredEndpoints = endpoints
        emit(.discovered(monitors.sorted { $0.name < $1.name }))
    }

    private func handleConnectionLoss(
        _ connection: NWConnection,
        error: Error?
    ) {
        guard activeConnection === connection else { return }
        activeConnection = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        clearPeerSession()

        if mode == .viewer,
           shouldMaintainViewerConnection,
           selectedViewerEndpoint != nil {
            scheduleReconnect()
        } else if mode == .monitor, listener != nil {
            emit(.state(.advertising))
        } else if mode != .idle {
            if let error {
                emit(.state(.failed(error.localizedDescription)))
            } else {
                emit(.state(.idle))
            }
        }
    }

    private func failProtocol(_ error: Error) {
        let connection = activeConnection
        activeConnection = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        clearPeerSession()

        if mode == .monitor, listener != nil {
            emit(.state(.advertising))
        } else {
            shouldMaintainViewerConnection = false
            selectedViewerEndpoint = nil
            reconnectToken = nil
            reconnectAttempt = 0
            emit(.state(.failed(error.localizedDescription)))
        }
    }

    private func scheduleReconnect() {
        guard
            mode == .viewer,
            shouldMaintainViewerConnection,
            let endpoint = selectedViewerEndpoint
        else {
            return
        }

        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let token = UUID()
        reconnectToken = token
        emit(.state(.reconnecting(attempt: attempt)))

        queue.asyncAfter(
            deadline: .now() + LocalReconnectPolicy.delay(
                forAttempt: attempt
            )
        ) { [weak self] in
            guard
                let self,
                self.reconnectToken == token,
                self.mode == .viewer,
                self.shouldMaintainViewerConnection,
                self.activeConnection == nil
            else {
                return
            }
            self.reconnectToken = nil
            self.emit(.state(.connecting))
            self.prepareConnection(
                NWConnection(to: endpoint, using: .tcp)
            )
        }
    }

    private func clearPeerSession() {
        framer = WirePacketFramer()
        pendingViewerHello = nil
        pendingMonitorPairing = nil
        pendingViewerPairing = nil
        pendingAuthentication = nil
        authenticatedPeer = nil
        diagnostics.authenticatedPeerCount = 0
        diagnostics.outboundVideoDepth = 0
        diagnostics.outboundAudioDepth = 0
        emit(.diagnostics(diagnostics))
    }

    private func stopLocked(emitIdle: Bool) {
        shouldMaintainViewerConnection = false
        selectedViewerEndpoint = nil
        reconnectToken = nil
        reconnectAttempt = 0
        if authenticatedPeer != nil {
            try? sendControl(ControlMessage(kind: .stop))
        }
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        let connection = activeConnection
        activeConnection = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        discoveredEndpoints = [:]
        clearPeerSession()
        diagnostics = LocalConnectionDiagnostics()
        mode = .idle
        if emitIdle {
            emit(.discovered([]))
            emit(.diagnostics(diagnostics))
            emit(.state(.idle))
        }
    }

    private func emit(_ event: Event) {
        eventHandler?(event)
    }
}

private nonisolated struct ViewerHello {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let clientNonce: Data
}

private nonisolated struct MonitorPairing {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let viewerID: String
    let viewerName: String
    let clientNonce: Data
    let serverNonce: Data
    let clientPublicKey: Data
}

private nonisolated struct ViewerPairing {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let monitorID: String
    let monitorName: String
    let clientNonce: Data
    let serverNonce: Data
    let clientPublicKey: Data
    let serverPublicKey: Data
    var pairingKey: SymmetricKey?
}

private nonisolated struct AuthenticationSession {
    let peerID: String
    let peerName: String
    let clientNonce: Data
    let serverNonce: Data
    let pairingSecret: Data
}

private nonisolated struct AuthenticatedPeer {
    let id: String
    let name: String
    let mediaKey: SymmetricKey
}

private nonisolated enum LocalConnectionError: LocalizedError {
    case invalidPairingCode
    case authenticationFailed
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidPairingCode:
            return "The pairing code did not match the Monitor."
        case .authenticationFailed:
            return "The saved private pairing could not be authenticated."
        case .notConnected:
            return "There is no local-network connection."
        }
    }
}
