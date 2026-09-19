#if RESOURCE_BENCH
import SwiftUI
import UIKit

struct ResourceBenchView: View {
    @Environment(\.scenePhase) private var phase
    @State private var controller = ResourceBenchController()
    var body: some View {
        VStack(spacing: 12) {
            Text("별무리 추론 자원 측정").font(.title2)
            Text(controller.message).font(.body)
            Text("진행 상황과 결과는 맥에 기록합니다.").font(.caption)
        }
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in controller.conditionChanged() }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification)) { _ in controller.conditionChanged() }
        .onChange(of: phase, initial: true) { _, value in
            if value == .active { Task { await controller.startOnce() } }
            else { controller.foregroundLost() }
        }
    }
}

@MainActor @Observable final class ResourceBenchController {
    var message = "맥의 실험 명령을 기다립니다."
    private var coordinator: RunCoordinator?
    private var started = false
    private var previousIdle = false
    private var previousBrightness: CGFloat = 0
    private var previousBatteryMonitoring = false
    private var actualBrightness: CGFloat = 0
    private var previousCondition: String?
    private var settingsApplied = false
    func startOnce() async {
        guard !started else { return }
        started = true
        var bootstrapFailure: URL?
        do {
            guard let runText = ProcessInfo.processInfo.environment["RESOURCE_BENCH_RUN_ID"],
                  let runID = UUID(uuidString: runText) else {
                message = "실행 ID가 없습니다. 맥에서 실험을 시작해 주세요."
                return
            }
            guard Bundle.main.bundleIdentifier?.hasSuffix(".resourcebench") == true else {
                throw BenchFailure.invalid("benchmark_requires_separate_bundle")
            }
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                       in: .userDomainMask, appropriateFor: nil, create: true)
            let root = support.appendingPathComponent("ResourceBench")
            let directory = root.appendingPathComponent("runs/\(runID.uuidString.lowercased())")
            bootstrapFailure = directory.appendingPathComponent("bootstrap-failure.json")
            let bytes = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            let plan = try BenchJSON.decoder.decode(BenchPlan.self, from: bytes)
            guard plan.run_id == runID else { throw BenchFailure.invalid("run_identity_mismatch") }
            try plan.validate()
            try claim(root: root, runID: runID)
            previousIdle = UIApplication.shared.isIdleTimerDisabled
            previousBrightness = UIScreen.main.brightness
            previousBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.isBatteryMonitoringEnabled = true
            UIScreen.main.brightness = CGFloat(plan.config.brightness)
            settingsApplied = true
            // UIKit can still return the old brightness immediately after assignment.
            // Wait for the requested value before defining the measurement baseline.
            let brightnessDeadline = ContinuousClock.now + .seconds(5)
            while abs(Double(UIScreen.main.brightness) - plan.config.brightness) > 0.000001 {
                guard ContinuousClock.now < brightnessDeadline else {
                    throw BenchFailure.invalid("brightness_not_applied_requested_\(plan.config.brightness)_observed_\(UIScreen.main.brightness)")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            actualBrightness = UIScreen.main.brightness
            let workload = InferenceBenchWorkload()
            let coordinator = try RunCoordinator(root: directory, modelsRoot: root, plan: plan,
                manifestHash: BenchIO.digest(bytes), workload: workload,
                environment: { [weak self] in try self?.checkEnvironment() },
                restore: { [weak self] in self?.restore() },
                recordEnvironment: { [weak self] in try self?.recordConditions() },
                initialConditions: { [weak self] in self?.thermalName == plan.config.required_initial_thermal_state })
            workload.journal = coordinator.journal
            self.coordinator = coordinator
            try coordinator.start()
            message = "맥에서 측정을 제어하고 있습니다."
        } catch {
            message = "실험 준비 실패: \(error)"
            NSLog("ResourceBench bootstrap failed: %@", String(describing: error))
            if let bootstrapFailure {
                do { try BenchIO.atomic(["error": String(describing: error)], to: bootstrapFailure) }
                catch { NSLog("ResourceBench bootstrap error could not be persisted: %@", String(describing: error)) }
            }
            if let coordinator { Task { await coordinator.abort(String(describing: error)) } }
            restore()
        }
    }
    private func claim(root: URL, runID: UUID) throws {
        let active = root.appendingPathComponent("active.json")
        if FileManager.default.fileExists(atPath: active.path) {
            let data = try Data(contentsOf: active)
            let prior = try BenchJSON.decoder.decode([String: UUID].self, from: data)
            guard let previous = prior["run_id"] else { throw BenchFailure.invalid("invalid_active_owner") }
            if previous != runID {
                let path = root.appendingPathComponent("runs/\(previous.uuidString.lowercased())/state.json")
                let state = try BenchJSON.decoder.decode(BenchState.self, from: Data(contentsOf: path))
                guard state.phase.terminal else { throw BenchFailure.invalid("device_busy") }
            }
        }
        try BenchIO.atomic(["run_id": runID], to: active)
    }
    private func checkEnvironment() throws {
        guard UIApplication.shared.applicationState == .active else { throw BenchFailure.invalid("app_not_foreground") }
        guard UIDevice.current.batteryState == .unplugged else { throw BenchFailure.invalid("device_not_unplugged") }
        guard UIScreen.main.brightness == actualBrightness else { throw BenchFailure.invalid("brightness_changed_expected_\(actualBrightness)_observed_\(UIScreen.main.brightness)") }
        let key = "\(thermalName):\(actualBrightness)"
        if previousCondition != key { try recordConditions(); previousCondition = key }
    }
    private var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
    private func recordConditions() throws {
        try coordinator?.journal.event("conditions", payload: ["foreground": UIApplication.shared.applicationState == .active,
            "charging": UIDevice.current.batteryState == .unplugged ? "unplugged" : "invalid",
            "brightness": Double(UIScreen.main.brightness), "thermal": thermalName,
            "battery_level": Double(UIDevice.current.batteryLevel)])
    }
    func conditionChanged() {
        guard let coordinator, !coordinator.store.state.phase.terminal else { return }
        do { try checkEnvironment() }
        catch { Task { await coordinator.abort(String(describing: error)) } }
    }
    func foregroundLost() {
        guard let coordinator else { return }
        Task { await coordinator.abort("app_not_foreground") }
    }
    private func restore() {
        guard settingsApplied else { return }
        UIApplication.shared.isIdleTimerDisabled = previousIdle
        UIScreen.main.brightness = previousBrightness
        UIDevice.current.isBatteryMonitoringEnabled = previousBatteryMonitoring
        settingsApplied = false
        if let coordinator { message = "실험 상태: \(coordinator.store.state.phase.rawValue)" }
    }
}
#endif
