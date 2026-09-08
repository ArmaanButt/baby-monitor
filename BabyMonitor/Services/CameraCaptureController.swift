@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class CameraCaptureController: ObservableObject {
    let session: AVCaptureSession
    let configuration: CameraCaptureConfiguration

    @Published private(set) var state: CameraCaptureState = .idle
    @Published private(set) var diagnostics = CameraDiagnostics()

    private let engine: CameraCaptureEngine
    private var wantsPreview = false

    init(configuration: CameraCaptureConfiguration = .highQuality) {
        self.configuration = configuration

        let engine = CameraCaptureEngine(configuration: configuration)
        self.engine = engine
        session = engine.session

        engine.eventHandler = { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }
    }

    func start() {
        guard !wantsPreview else { return }

        wantsPreview = true

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            state = .configuring
            engine.start()
        case .notDetermined:
            state = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.wantsPreview else { return }

                    if granted {
                        self.state = .configuring
                        self.engine.start()
                    } else {
                        self.wantsPreview = false
                        self.state = .denied
                    }
                }
            }
        case .denied, .restricted:
            wantsPreview = false
            state = .denied
        @unknown default:
            wantsPreview = false
            state = .failed("The device returned an unknown camera authorization state.")
        }
    }

    func stop() {
        guard state.isEngaged else { return }

        wantsPreview = false
        state = .stopping
        engine.stop(finalEvent: .stopped)
    }

    func handleScenePhase(isActive: Bool) {
        guard wantsPreview else { return }

        if isActive {
            state = .configuring
            engine.start()
        } else {
            state = .suspended
            engine.stop(finalEvent: .suspended)
        }
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        diagnostics = CameraDiagnostics()
        engine.setDiagnosticsEnabled(enabled)
    }

    private func handle(_ event: CameraCaptureEngine.Event) {
        switch event {
        case .running:
            guard wantsPreview else {
                engine.stop(finalEvent: .stopped)
                return
            }
            state = .running
        case .interrupted(let message):
            if wantsPreview {
                state = .interrupted(message)
                diagnostics.captureBufferDepth = 0
            }
        case .interruptionEnded:
            if wantsPreview {
                state = .running
            }
        case .suspended:
            if wantsPreview {
                state = .suspended
                diagnostics.captureBufferDepth = 0
            }
        case .stopped:
            if !wantsPreview {
                state = .idle
                diagnostics.captureBufferDepth = 0
            }
        case .failed(let message):
            wantsPreview = false
            state = .failed(message)
        case .diagnostics(let snapshot):
            diagnostics = snapshot
        }
    }
}

private nonisolated final class CameraCaptureEngine:
    NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    enum Event {
        case running
        case interrupted(String)
        case interruptionEnded
        case suspended
        case stopped
        case failed(String)
        case diagnostics(CameraDiagnostics)
    }

    let session = AVCaptureSession()
    var eventHandler: ((Event) -> Void)?

    private let configuration: CameraCaptureConfiguration
    private let sessionQueue = DispatchQueue(label: "com.armaanbutt.BabyMonitor.camera.session")
    private let frameQueue = DispatchQueue(
        label: "com.armaanbutt.BabyMonitor.camera.frames",
        qos: .userInitiated
    )
    private var isConfigured = false
    private var observerTokens: [NSObjectProtocol] = []

    private var capturedFrameCount = 0
    private var droppedFrameCount = 0
    private var framesInWindow = 0
    private var windowStartedAt = ProcessInfo.processInfo.systemUptime
    private var accumulatedProcessingMilliseconds = 0.0
    private var diagnosticsEnabled = true

    init(configuration: CameraCaptureConfiguration) {
        self.configuration = configuration
        super.init()
        observeSessionNotifications()
    }

    deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                if !self.isConfigured {
                    try self.configureSession()
                    self.isConfigured = true
                }

                guard !self.session.isRunning else {
                    self.emit(.running)
                    return
                }

                self.resetDiagnostics()
                self.session.startRunning()
                self.emit(.running)
            } catch {
                self.emit(.failed(error.localizedDescription))
            }
        }
    }

    func stop(finalEvent: Event) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.emit(finalEvent)
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canSetSessionPreset(configuration.sessionPreset) else {
            throw CameraCaptureError.unsupported1080p
        }
        session.sessionPreset = configuration.sessionPreset

        guard
            let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            )
        else {
            throw CameraCaptureError.noBackCamera
        }

        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)

        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }

        let frameDuration = CMTime(value: 1, timescale: configuration.framesPerSecond)
        let supportsFrameRate = camera.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= Double(configuration.framesPerSecond)
                && Double(configuration.framesPerSecond) <= $0.maxFrameRate
        }

        guard supportsFrameRate else {
            throw CameraCaptureError.unsupportedFrameRate(configuration.framesPerSecond)
        }

        camera.activeVideoMinFrameDuration = frameDuration
        camera.activeVideoMaxFrameDuration = frameDuration

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: frameQueue)

        guard session.canAddOutput(output) else {
            throw CameraCaptureError.cannotAddOutput
        }
        session.addOutput(output)
    }

    private func observeSessionNotifications() {
        let center = NotificationCenter.default

        observerTokens.append(
            center.addObserver(
                forName: .AVCaptureSessionWasInterrupted,
                object: session,
                queue: nil
            ) { [weak self] notification in
                let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey]
                    as? NSNumber
                self?.emit(.interrupted(Self.interruptionMessage(for: reason)))
            }
        )

        observerTokens.append(
            center.addObserver(
                forName: .AVCaptureSessionInterruptionEnded,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.emit(.interruptionEnded)
            }
        )

        observerTokens.append(
            center.addObserver(
                forName: .AVCaptureSessionRuntimeError,
                object: session,
                queue: nil
            ) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.sessionQueue.async {
                    guard let self else { return }
                    if self.session.isRunning {
                        self.session.stopRunning()
                    }
                    self.emit(.failed(error?.localizedDescription ?? "The camera session stopped unexpectedly."))
                }
            }
        )
    }

    private static func interruptionMessage(for rawReason: NSNumber?) -> String {
        guard
            let rawReason,
            let reason = AVCaptureSession.InterruptionReason(rawValue: rawReason.intValue)
        else {
            return "Camera capture was interrupted by the system."
        }

        switch reason {
        case .audioDeviceInUseByAnotherClient:
            return "Another app is using the audio device."
        case .videoDeviceInUseByAnotherClient:
            return "Another app is using the camera."
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "The camera is unavailable while multiple apps are in the foreground."
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "The camera paused because of system pressure."
        default:
            return "Camera capture was interrupted by the system."
        }
    }

    private func resetDiagnostics() {
        frameQueue.async { [weak self] in
            self?.capturedFrameCount = 0
            self?.droppedFrameCount = 0
            self?.framesInWindow = 0
            self?.windowStartedAt = ProcessInfo.processInfo.systemUptime
            self?.accumulatedProcessingMilliseconds = 0
        }
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.diagnosticsEnabled = enabled
            self.capturedFrameCount = 0
            self.droppedFrameCount = 0
            self.framesInWindow = 0
            self.accumulatedProcessingMilliseconds = 0
            self.windowStartedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard diagnosticsEnabled else { return }
        let processingStartedAt = ProcessInfo.processInfo.systemUptime
        capturedFrameCount += 1
        framesInWindow += 1

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - windowStartedAt
        guard elapsed >= 1 else {
            accumulatedProcessingMilliseconds +=
                (ProcessInfo.processInfo.systemUptime - processingStartedAt) * 1_000
            return
        }

        let dimensions: CMVideoDimensions
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        } else {
            dimensions = CMVideoDimensions(width: 0, height: 0)
        }

        accumulatedProcessingMilliseconds +=
            (ProcessInfo.processInfo.systemUptime - processingStartedAt) * 1_000

        let snapshot = CameraDiagnostics(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            framesPerSecond: Double(framesInWindow) / elapsed,
            capturedFrameCount: capturedFrameCount,
            droppedFrameCount: droppedFrameCount,
            averageCaptureProcessingMilliseconds:
                accumulatedProcessingMilliseconds / Double(capturedFrameCount),
            captureBufferDepth: 1
        )

        framesInWindow = 0
        windowStartedAt = now
        emit(.diagnostics(snapshot))
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard diagnosticsEnabled else { return }
        droppedFrameCount += 1
    }

    private func emit(_ event: Event) {
        eventHandler?(event)
    }

}

private extension CameraCaptureConfiguration {
    nonisolated var sessionPreset: AVCaptureSession.Preset {
        switch (width, height) {
        case (1_280, 720):
            return .hd1280x720
        default:
            return .hd1920x1080
        }
    }
}

private enum CameraCaptureError: LocalizedError {
    case noBackCamera
    case unsupported1080p
    case unsupportedFrameRate(Int32)
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noBackCamera:
            return "No back camera is available on this device."
        case .unsupported1080p:
            return "This camera does not support the required 1920×1080 preview."
        case .unsupportedFrameRate(let framesPerSecond):
            return "This camera does not support \(framesPerSecond) FPS in the selected format."
        case .cannotAddInput:
            return "The camera input could not be added to the capture session."
        case .cannotAddOutput:
            return "The video output could not be added to the capture session."
        }
    }
}
