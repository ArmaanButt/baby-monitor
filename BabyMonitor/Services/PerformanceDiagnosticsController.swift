import Combine
import Darwin
import Foundation
import UIKit

@MainActor
final class PerformanceDiagnosticsController: ObservableObject {
    static let enabledDefaultsKey = "performance-diagnostics-enabled"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var system = SystemDiagnostics()
    @Published var testContext = DiagnosticsTestContext()

    private let defaults: UserDefaults
    private var role: DiagnosticsRole?
    private var timer: Timer?
    private var startedAt = ProcessInfo.processInfo.systemUptime

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.enabledDefaultsKey) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        }
    }

    deinit {
        timer?.invalidate()
    }

    func begin(role: DiagnosticsRole) {
        guard self.role != role else { return }
        self.role = role
        resetSession()
        updateSampling()
    }

    func end(role: DiagnosticsRole) {
        guard self.role == role else { return }
        self.role = nil
        timer?.invalidate()
        timer = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        resetSession()
        updateSampling()
    }

    func makeReport(
        role: DiagnosticsRole,
        camera: CameraDiagnostics = CameraDiagnostics(),
        encoder: VideoEncoderDiagnostics = VideoEncoderDiagnostics(),
        audio: RoomAudioCaptureDiagnostics = RoomAudioCaptureDiagnostics(),
        viewer: ViewerDiagnostics = .unavailable
    ) -> DiagnosticsReport {
        DiagnosticsReport(
            role: role,
            system: system,
            camera: camera,
            encoder: encoder,
            audio: audio,
            viewer: viewer,
            context: testContext
        )
    }

    private func resetSession() {
        startedAt = ProcessInfo.processInfo.systemUptime
        system = SystemDiagnostics()
        guard isEnabled else { return }
        sample()
    }

    private func updateSampling() {
        timer?.invalidate()
        timer = nil

        guard isEnabled, role != nil else {
            UIDevice.current.isBatteryMonitoringEnabled = false
            return
        }

        UIDevice.current.isBatteryMonitoringEnabled = true
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
    }

    private func sample() {
        let sample = SystemDiagnosticsSampler.sample()
        system.deviceIdentifier = sample.deviceIdentifier
        system.operatingSystem = sample.operatingSystem
        system.powerState = sample.powerState
        system.thermalState = sample.thermalState
        system.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedAt
        system.memory.record(megabytes: sample.residentMemoryMegabytes)
    }
}

private nonisolated enum SystemDiagnosticsSampler {
    struct Sample {
        let deviceIdentifier: String
        let operatingSystem: String
        let powerState: String
        let thermalState: String
        let residentMemoryMegabytes: Double
    }

    @MainActor
    static func sample() -> Sample {
        let device = UIDevice.current
        return Sample(
            deviceIdentifier: machineIdentifier,
            operatingSystem: "\(device.systemName) \(device.systemVersion)",
            powerState: powerStateLabel(device: device),
            thermalState: thermalStateLabel,
            residentMemoryMegabytes: residentMemoryMegabytes()
        )
    }

    private static var machineIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)

        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    @MainActor
    private static func powerStateLabel(device: UIDevice) -> String {
        let percent: String
        if device.batteryLevel >= 0 {
            percent = " • \(Int((device.batteryLevel * 100).rounded()))%"
        } else {
            percent = ""
        }

        switch device.batteryState {
        case .charging:
            return "Charging\(percent)"
        case .full:
            return "Full\(percent)"
        case .unplugged:
            return "Battery\(percent)"
        case .unknown:
            return "Unknown"
        @unknown default:
            return "Unknown"
        }
    }

    private static var thermalStateLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Fair"
        case .serious:
            return "Serious"
        case .critical:
            return "Critical"
        @unknown default:
            return "Unknown"
        }
    }

    private static func residentMemoryMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }
}
