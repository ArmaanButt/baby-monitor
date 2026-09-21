@preconcurrency import AVFoundation
import Combine
import Foundation
@preconcurrency import WebRTC

@MainActor
final class WebRTCStreamController: ObservableObject {
    @Published private(set) var state: WebRTCStreamState = .idle
    @Published private(set) var diagnostics = WebRTCStreamDiagnostics()
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?

    nonisolated let engine: WebRTCStreamEngine

    init(connection: LocalConnectionController) {
        let engine = WebRTCStreamEngine()
        self.engine = engine
        engine.signalHandler = { [weak connection] signal, channelID in
            connection?.sendWebRTC(signal, channelID: channelID)
        }
        engine.reconnectHandler = { [weak connection] channelID in
            connection?.reconnectMedia(channelID: channelID)
        }
        engine.eventHandler = { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                switch event {
                case .state(let state): self.state = state
                case .track(let track): self.remoteVideoTrack = track
                case .diagnostics(let diagnostics): self.diagnostics = diagnostics
                }
            }
        }
        connection.setWebRTCHandler { [weak engine] event in engine?.handle(event) }
    }

    func setMonitoring(profile: StreamVideoProfile?) {
        engine.setMonitoring(profile: profile)
    }

    nonisolated func capture(_ sampleBuffer: CMSampleBuffer) {
        engine.capture(sampleBuffer)
    }
}

/// All negotiation and session state belongs to this serial queue. The capture
/// boundary reserves one raw frame; decoded reference frames are never discarded
/// by an application admission queue.
nonisolated final class WebRTCStreamEngine: NSObject, @unchecked Sendable {
    enum Event {
        case state(WebRTCStreamState)
        case track(RTCVideoTrack?)
        case diagnostics(WebRTCStreamDiagnostics)
    }

    var eventHandler: (@Sendable (Event) -> Void)?
    var signalHandler: (@Sendable (WebRTCSignal, UUID) -> Void)?
    var reconnectHandler: (@Sendable (UUID) -> Void)?

    private static let initializeSSL: Void = { RTCInitializeSSL() }()
    private let queue = DispatchQueue(label: "com.armaanbutt.BabyMonitor.webrtc", qos: .userInitiated)
    private let captureCapacity = DispatchSemaphore(value: 1)
    private let enableAudio: Bool
    private var factoryStorage: RTCPeerConnectionFactory?
    private var factoryRole: DeviceRole?
    private var playbackAudioDevice: WebRTCPlaybackAudioDevice?
    private var factory: RTCPeerConnectionFactory {
        if let factoryStorage, factoryRole == role { return factoryStorage }
        Self.initializeSSL
        let audioDevice = role == .viewer && enableAudio ? WebRTCPlaybackAudioDevice() : nil
        playbackAudioDevice = audioDevice
        audioDevice?.statusHandler = { [weak self, weak audioDevice] status in
            self?.queue.async {
                guard let self, let audioDevice,
                      self.playbackAudioDevice === audioDevice, self.peer != nil else { return }
                self.diagnostics.audioPlaybackStatus = status
                self.emit(.diagnostics(self.diagnostics))
            }
        }
        let factory = RTCPeerConnectionFactory(
            encoderFactory: WebRTCH264EncoderFactory(),
            decoderFactory: WebRTCH264DecoderFactory(),
            audioDevice: audioDevice
        )
        let options = RTCPeerConnectionFactoryOptions()
        options.disableEncryption = false
        options.ignoreCellularNetworkAdapter = true
        options.ignoreVPNNetworkAdapter = true
        factory.setOptions(options)
        factoryStorage = factory
        factoryRole = role
        return factory
    }
    private var peer: RTCPeerConnection?
    private var role: DeviceRole?
    private var channelID: UUID?
    private var streamID: UUID?
    private var monitoringProfile: StreamVideoProfile?
    private var videoSource: RTCVideoSource?
    private var videoCapturer: RTCVideoCapturer?
    private var videoSender: RTCRtpSender?
    private var localDescriptionSent = false
    private var remoteDescriptionSet = false
    private var pendingLocalCandidates: [WebRTCSignal] = []
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var diagnostics = WebRTCStreamDiagnostics()
    private var statisticsTimer: DispatchSourceTimer?
    private var statsPending = false
    private var interruptionObserver: NSObjectProtocol?
    private var recoveryToken: UUID?
    private var lastVideoProgress = ProcessInfo.processInfo.systemUptime

    // The test harness disables device audio while exercising real H.264/ICE.
    init(enableAudio: Bool = true) {
        self.enableAudio = enableAudio
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            self?.queue.async {
                guard let self, self.peer != nil else { return }
                self.diagnostics.audioInterrupted = raw == AVAudioSession.InterruptionType.began.rawValue
                self.emit(.diagnostics(self.diagnostics))
            }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        statisticsTimer?.cancel()
        peer?.close()
    }

    func handle(_ event: WebRTCChannelEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            switch event {
            case .authenticated(let id, let role):
                self.closePeer()
                self.channelID = id
                self.role = role
                self.emit(.state(.waitingForMonitor))
                if role == .monitor, let profile = self.monitoringProfile {
                    self.startOffer(profile: profile)
                }
            case .disconnected:
                self.closePeer()
                self.channelID = nil
                self.role = nil
                self.emit(.state(.idle))
            case .signal(let channelID, let signal):
                guard self.channelID == channelID else { return }
                self.receive(signal)
            }
        }
    }

    func setMonitoring(profile: StreamVideoProfile?) {
        queue.async { [weak self] in
            guard let self, self.monitoringProfile != profile else { return }
            self.monitoringProfile = profile
            if let id = self.streamID, self.role == .monitor {
                self.send(WebRTCSignal(kind: .stop, streamID: id))
            }
            self.closePeer()
            if self.role == .monitor, self.channelID != nil, let profile {
                self.startOffer(profile: profile)
            } else {
                self.emit(.state(self.channelID == nil ? .idle : .waitingForMonitor))
            }
        }
    }

    func capture(_ sampleBuffer: CMSampleBuffer) {
        guard captureCapacity.wait(timeout: .now()) == .success else { return }
        let sample = WebRTCSampleBuffer(value: sampleBuffer)
        queue.async { [weak self, captureCapacity] in
            defer { captureCapacity.signal() }
            guard let self, self.monitoringProfile != nil,
                  let source = self.videoSource, let capturer = self.videoCapturer,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample.value) else { return }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample.value)
            guard timestamp.isValid, timestamp.isNumeric else { return }
            let frame = RTCVideoFrame(
                buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                rotation: ._0,
                timeStampNs: CMTimeConvertScale(timestamp, timescale: 1_000_000_000, method: .default).value
            )
            source.capturer(capturer, didCapture: frame)
        }
    }

    private func makePeer(streamID: UUID, profile: StreamVideoProfile) throws -> RTCPeerConnection {
        closePeer()
        self.streamID = streamID
        diagnostics = WebRTCStreamDiagnostics(profile: profile)
        lastVideoProgress = ProcessInfo.processInfo.systemUptime
        if enableAudio, role == .monitor {
            let config = RTCAudioSessionConfiguration.webRTC()
            config.category = AVAudioSession.Category.playAndRecord.rawValue
            config.mode = AVAudioSession.Mode.videoChat.rawValue
            config.categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
            RTCAudioSessionConfiguration.setWebRTC(config)
        }
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []
        config.iceTransportPolicy = .all
        config.tcpCandidatePolicy = .disabled
        config.candidateNetworkPolicy = .lowCost
        config.continualGatheringPolicy = .gatherOnce
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.audioJitterBufferMaxPackets = 50
        config.audioJitterBufferFastAccelerate = true
        guard let peer = factory.peerConnection(
            with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: self
        ) else { throw WebRTCSignalingError.invalidMessage }
        self.peer = peer
        emit(.state(.connecting))
        startStatistics(for: peer)
        scheduleRecovery(for: peer, after: 20)
        return peer
    }

    private func startOffer(profile: StreamVideoProfile) {
        guard role == .monitor, channelID != nil else { return }
        do {
            let peer = try makePeer(streamID: UUID(), profile: profile)
            let source = factory.videoSource()
            source.adaptOutputFormat(toWidth: profile.width, height: profile.height, fps: profile.framesPerSecond)
            videoSource = source
            videoCapturer = RTCVideoCapturer(delegate: source)
            let video = factory.videoTrack(with: source, trackId: "room-video")
            let videoInit = RTCRtpTransceiverInit()
            videoInit.direction = .sendOnly
            videoInit.streamIds = ["room"]
            guard let transceiver = peer.addTransceiver(with: video, init: videoInit) else {
                throw WebRTCSignalingError.invalidMessage
            }
            videoSender = transceiver.sender
            applyVideoProfile()
            if enableAudio {
                let constraints = RTCMediaConstraints(mandatoryConstraints: [
                    "googEchoCancellation": "false", "googAutoGainControl": "false",
                    "googNoiseSuppression": "false", "googHighpassFilter": "false"
                ], optionalConstraints: nil)
                let audio = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "room-audio")
                let audioInit = RTCRtpTransceiverInit()
                audioInit.direction = .sendOnly
                audioInit.streamIds = ["room"]
                guard peer.addTransceiver(with: audio, init: audioInit) != nil else {
                    throw WebRTCSignalingError.invalidMessage
                }
            }
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) {
                [weak self, weak peer] description, error in
                self?.queue.async {
                    guard let self, let peer, self.peer === peer else { return }
                    self.publish(description, error: error, peer: peer, kind: .offer)
                }
            }
        } catch { fail(error) }
    }

    private func applyVideoProfile() {
        guard let sender = videoSender else { return }
        let profile = diagnostics.profile
        let parameters = sender.parameters
        parameters.degradationPreference = NSNumber(
            value: RTCDegradationPreference.maintainFramerateAndResolution.rawValue
        )
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: profile.averageBitrate)
            encoding.maxFramerate = NSNumber(value: profile.framesPerSecond)
            encoding.scaleResolutionDownBy = 1
            encoding.isActive = true
        }
        sender.parameters = parameters
    }

    private func publish(
        _ description: RTCSessionDescription?, error: Error?,
        peer: RTCPeerConnection, kind: WebRTCSignal.Kind
    ) {
        if let error { fail(error); return }
        guard let description, let streamID else { fail(WebRTCSignalingError.invalidMessage); return }
        peer.setLocalDescription(description) { [weak self, weak peer] error in
            self?.queue.async {
                guard let self, let peer, self.peer === peer else { return }
                if let error { self.fail(error); return }
                self.applyVideoProfile()
                // Send the original SDP (without gathered candidates). Every
                // candidate passes our LAN filter and follows the description.
                self.send(WebRTCSignal(
                    kind: kind, streamID: streamID, sdp: description.sdp,
                    profile: kind == .offer ? self.diagnostics.profile : nil
                ))
                self.localDescriptionSent = true
                let candidates = self.pendingLocalCandidates
                self.pendingLocalCandidates.removeAll()
                candidates.forEach(self.send)
            }
        }
    }

    private func receive(_ signal: WebRTCSignal) {
        do {
            try signal.validate()
            switch signal.kind {
            case .offer:
                guard role == .viewer, let sdp = signal.sdp, let profile = signal.profile else {
                    throw WebRTCSignalingError.invalidMessage
                }
                let peer = try makePeer(streamID: signal.streamID, profile: profile)
                setRemote(RTCSessionDescription(type: .offer, sdp: sdp), peer: peer, answer: true)
            case .answer:
                guard role == .monitor, signal.streamID == streamID,
                      let peer, let sdp = signal.sdp, !remoteDescriptionSet else { return }
                setRemote(RTCSessionDescription(type: .answer, sdp: sdp), peer: peer, answer: false)
            case .candidate:
                guard signal.streamID == streamID, let peer,
                      let sdp = signal.sdp, let index = signal.sdpMLineIndex else { return }
                let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: signal.sdpMid)
                if remoteDescriptionSet {
                    add(candidate, to: peer)
                } else {
                    guard pendingRemoteCandidates.count < 64 else {
                        throw WebRTCSignalingError.invalidMessage
                    }
                    pendingRemoteCandidates.append(candidate)
                }
            case .stop:
                guard role == .viewer, signal.streamID == streamID else { return }
                closePeer()
                emit(.state(.waitingForMonitor))
            }
        } catch { fail(error) }
    }

    private func setRemote(_ description: RTCSessionDescription, peer: RTCPeerConnection, answer: Bool) {
        peer.setRemoteDescription(description) { [weak self, weak peer] error in
            self?.queue.async {
                guard let self, let peer, self.peer === peer else { return }
                if let error { self.fail(error); return }
                self.remoteDescriptionSet = true
                let candidates = self.pendingRemoteCandidates
                self.pendingRemoteCandidates.removeAll()
                candidates.forEach { self.add($0, to: peer) }
                self.applyVideoProfile()
                guard answer else { return }
                // Viewer never creates local tracks or opens camera/microphone.
                do {
                    for transceiver in peer.transceivers {
                        var error: NSError?
                        transceiver.setDirection(.recvOnly, error: &error)
                        if let error { throw error }
                    }
                } catch { self.fail(error); return }
                peer.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) {
                    [weak self, weak peer] description, error in
                    self?.queue.async {
                        guard let self, let peer, self.peer === peer else { return }
                        self.publish(description, error: error, peer: peer, kind: .answer)
                    }
                }
            }
        }
    }

    private func add(_ candidate: RTCIceCandidate, to peer: RTCPeerConnection) {
        peer.add(candidate) { [weak self, weak peer] error in
            self?.queue.async {
                guard let self, let peer, self.peer === peer, let error else { return }
                self.fail(error)
            }
        }
    }

    private func send(_ signal: WebRTCSignal) {
        guard let channelID else { return }
        signalHandler?(signal, channelID)
    }

    private func closePeer() {
        recoveryToken = nil
        statisticsTimer?.cancel()
        statisticsTimer = nil
        statsPending = false
        let old = peer
        peer = nil
        videoSource = nil
        videoCapturer = nil
        videoSender = nil
        streamID = nil
        localDescriptionSent = false
        remoteDescriptionSet = false
        pendingLocalCandidates.removeAll()
        pendingRemoteCandidates.removeAll()
        old?.delegate = nil
        old?.close()
        emit(.track(nil))
        diagnostics = WebRTCStreamDiagnostics(profile: monitoringProfile ?? diagnostics.profile)
        emit(.diagnostics(diagnostics))
    }

    private func fail(_ error: Error) {
        closePeer()
        // SDK error descriptions can contain SDP/IP addresses. Keep them out of
        // user-copyable diagnostics; expose a stable, actionable error instead.
        let code = (error as NSError).code
        diagnostics.lastMediaError = "Stream setup failed (\(code))."
        emit(.diagnostics(diagnostics))
        emit(.state(.failed("The private stream could not start (\(code)). Disconnect and reconnect both devices.")))
    }

    private func scheduleRecovery(for peer: RTCPeerConnection, after delay: Double) {
        let token = UUID()
        recoveryToken = token
        queue.asyncAfter(deadline: .now() + delay) { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer, self.recoveryToken == token,
                  let channelID = self.channelID else { return }
            self.closePeer()
            self.emit(.state(.reconnecting))
            self.reconnectHandler?(channelID)
        }
    }

    private func startStatistics(for peer: RTCPeerConnection) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer, !self.statsPending else { return }
            self.statsPending = true
            peer.statistics { [weak self, weak peer] report in
                self?.queue.async {
                    guard let self, let peer, self.peer === peer else { return }
                    self.statsPending = false
                    self.updateStatistics(report, peer: peer)
                }
            }
        }
        statisticsTimer = timer
        timer.resume()
    }

    private func updateStatistics(_ report: RTCStatisticsReport, peer: RTCPeerConnection) {
        let outbound = role == .monitor
        let previousFrames = diagnostics.frames
        for stat in report.statistics.values {
            let value = stat.values
            func number(_ key: String) -> Double { (value[key] as? NSNumber)?.doubleValue ?? 0 }
            let kind = value["kind"] as? String ?? value["mediaType"] as? String
            if stat.type == (outbound ? "outbound-rtp" : "inbound-rtp"), kind == "video" {
                diagnostics.width = Int(number("frameWidth"))
                diagnostics.height = Int(number("frameHeight"))
                diagnostics.framesPerSecond = number("framesPerSecond")
                diagnostics.frames = Int(number(outbound ? "framesEncoded" : "framesDecoded"))
                diagnostics.bytes = Int(number(outbound ? "bytesSent" : "bytesReceived"))
                diagnostics.packetsLost = Int(number("packetsLost"))
                diagnostics.keyFrameRequests = Int(number("pliCount"))
                diagnostics.retransmissions = Int(number(
                    outbound ? "retransmittedPacketsSent" : "retransmittedPacketsReceived"
                ))
                diagnostics.codecImplementation = value[outbound ? "encoderImplementation" : "decoderImplementation"] as? String ?? "Not reported"
                diagnostics.qualityLimitation = value["qualityLimitationReason"] as? String ?? "Not reported"
                if let codecID = value["codecId"] as? String,
                   let codec = report.statistics[codecID]?.values["mimeType"] as? String {
                    diagnostics.codec = codec
                }
                if !outbound, diagnostics.frames > 0, peer.connectionState == .connected {
                    emit(.state(.live))
                }
            }
            if stat.type == (outbound ? "outbound-rtp" : "inbound-rtp"), kind == "audio" {
                diagnostics.audioPackets = Int(number(outbound ? "packetsSent" : "packetsReceived"))
                diagnostics.audioConcealedSamples = Int(number("concealedSamples"))
            }
            if stat.type == "candidate-pair", value["state"] as? String == "succeeded",
               (value["nominated"] as? NSNumber)?.boolValue == true {
                diagnostics.roundTripMilliseconds = number("currentRoundTripTime") * 1_000
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if diagnostics.frames > previousFrames {
            lastVideoProgress = now
            if peer.connectionState == .connected { recoveryToken = nil }
        }
        if peer.connectionState == .connected, now - lastVideoProgress > 10 {
            // A connected transport is not proof of live video. Recover a
            // stalled codec/session instead of leaving a frozen image as Live.
            emit(.state(.reconnecting))
            if recoveryToken == nil { scheduleRecovery(for: peer, after: 1) }
        }
        if enableAudio {
            diagnostics.audioRoute = AVAudioSession.sharedInstance().currentRoute.outputs
                .map(\.portType.rawValue).joined(separator: ", ")
        }
        emit(.diagnostics(diagnostics))
    }

    private func emit(_ event: Event) { eventHandler?(event) }
}

extension WebRTCStreamEngine: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.close()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        queue.async { [weak self] in
            guard let self, self.peer === peerConnection, let streamID = self.streamID,
                  LocalICECandidate.isAllowed(candidate.sdp) else { return }
            let signal = WebRTCSignal(
                kind: .candidate, streamID: streamID, sdp: candidate.sdp,
                sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex
            )
            if self.localDescriptionSent {
                self.send(signal)
            } else if self.pendingLocalCandidates.count < 64 {
                self.pendingLocalCandidates.append(signal)
            } else {
                self.fail(WebRTCSignalingError.invalidMessage)
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        queue.async { [weak self] in
            guard let self, self.peer === peerConnection else { return }
            switch newState {
            case .connected:
                self.recoveryToken = nil
                self.emit(.state(self.role == .monitor ? .live : .connecting))
            case .disconnected, .failed:
                self.emit(.state(.reconnecting))
                self.scheduleRecovery(for: peerConnection, after: newState == .failed ? 1 : 8)
            default: break
            }
        }
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        queue.async { [weak self] in
            guard let self, self.peer === peerConnection, self.role == .viewer,
                  let video = rtpReceiver.track as? RTCVideoTrack else { return }
            self.emit(.track(video))
        }
    }
}

private nonisolated struct WebRTCSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}
