import DiscBridge
import Foundation
import Observation

@MainActor @Observable
public final class BurnStore {
    public var mode: StudioMode = .burn
    public let imageCreation = ImageCreationStore()
    public private(set) var devices: [DiscDevice] = []
    public var selectedDeviceID = ""
    public private(set) var sessions: [BurnSession]
    public private(set) var isDemo = false

    @ObservationIgnored private let deviceMonitor = BRDiscEngine()
    @ObservationIgnored private let makeEngine: () -> any BurnSessionEngine
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var savedSessions: [BurnSession] = []
    @ObservationIgnored private var savedDeviceID = ""
    private var sharedPreparation: SharedBurnPreparation?

    public convenience init() { self.init(makeEngine: { NativeBurnSessionEngine() }) }

    init(makeEngine: @escaping () -> any BurnSessionEngine) {
        self.makeEngine = makeEngine
        sessions = [BurnSession(engine: makeEngine())]
    }

    public var selectedSession: BurnSession {
        sessions.first { $0.deviceID == selectedDeviceID } ?? sessions[0]
    }
    public var selectedDevice: DiscDevice? { devices.first { $0.id == selectedDeviceID } }
    public func label(for session: BurnSession) -> String {
        guard !session.deviceID.isEmpty, let index = sessions.firstIndex(where: { $0.id == session.id }) else {
            return session.deviceName
        }
        return "设备 \(index + 1) · \(session.deviceName)"
    }
    public var image: DiscImage? { selectedSession.image }
    public var snapshot: BurnSnapshot { selectedSession.snapshot }
    public var options: BurnOptions {
        get { selectedSession.options }
        set { if canEditSelectedSession { selectedSession.options = newValue } }
    }
    public var errorMessage: String? {
        get { selectedSession.errorMessage }
        set { selectedSession.errorMessage = newValue }
    }
    /// App-wide activity is used for quitting, mode changes and image creation only.
    public var isBusy: Bool { sessions.contains { $0.isBusy } || imageCreation.isBusy || sharedPreparation != nil }
    public var isLoadingImage: Bool { sessions.contains { $0.isLoadingImage } }
    public var activeBurnCount: Int { sessions.filter { $0.isBusy }.count }
    public var canEditSelectedSession: Bool {
        !isDemo && !imageCreation.isBusy && !selectedSession.isBusy && !isReserved(selectedSession)
    }
    public var preflightIssue: String? { selectedSession.preflightIssue }
    public var canBurn: Bool { canEditSelectedSession && selectedSession.canBurn }
    public var readySessions: [BurnSession] {
        guard !isDemo, !imageCreation.isBusy else { return [] }
        return sessions.filter { $0.canBurn && !isReserved($0) }
    }
    public var canApplyImageToOtherDevices: Bool { image != nil && !imageCopyTargets.isEmpty }
    private var imageCopyTargets: [BurnSession] {
        guard !isDemo, !imageCreation.isBusy else { return [] }
        return sessions.filter {
            $0.id != selectedSession.id && $0.device != nil && !$0.isBusy && !$0.isLoadingImage && !isReserved($0)
        }
    }

    public func connect() {
        guard !didStart else { return }
        didStart = true
        deviceMonitor.onDevices = { [weak self] values in
            let devices = values.map(DiscDevice.init(dictionary:))
            MainActor.assumeIsolated { self?.updateDevices(devices) }
        }
        deviceMonitor.observeDevices()
    }

    func updateDevices(_ devices: [DiscDevice]) {
        guard !isDemo else { return }
        self.devices = devices
        for device in devices where !sessions.contains(where: { $0.deviceID == device.id }) {
            if let draft = sessions.first(where: { $0.deviceID.isEmpty }) {
                draft.updateDevice(device)
            } else {
                let session = BurnSession(engine: makeEngine())
                session.updateDevice(device)
                sessions.append(session)
            }
        }
        // Keep disconnected sessions (including active ones) and their logs until the engine finishes cleanup.
        for session in sessions {
            session.updateDevice(devices.first { $0.id == session.deviceID })
        }
        if selectedDeviceID.isEmpty { selectedDeviceID = devices.first?.id ?? "" }
    }

    public func refreshDevices() { if !isDemo { deviceMonitor.refreshDevices() } }

    public func selectImage(_ url: URL, sessionID: UUID? = nil) {
        guard !isDemo, !imageCreation.isBusy else { return }
        let target = sessionID.map { id in sessions.first { $0.id == id } } ?? selectedSession
        guard let session = target, !session.isBusy, !isReserved(session) else { return }
        session.selectImage(url)
    }

    public func applyImageToOtherDevices() {
        guard let url = image?.url else { return }
        // Reparse on each engine so DRTrack producers and verification state stay independent.
        for session in imageCopyTargets { session.selectImage(url) }
    }

    public func startBurn() { startBurns([selectedSession.burnRequest].compactMap { $0 }) }

    public func startBurns(_ requests: [BurnRequest]) {
        guard !isDemo, !imageCreation.isBusy else { return }
        var started = Set<UUID>()
        for request in requests where started.insert(request.sessionID).inserted {
            guard let session = sessions.first(where: { $0.id == request.sessionID }) else { continue }
            guard !session.isBusy, !isReserved(session) else { continue }
            guard session.burnRequest == request else {
                session.errorMessage = session.preflightIssue ?? "镜像或刻录选项已改变，请重新确认。"
                continue
            }
            // A synchronous failure on one drive must not prevent the other confirmed jobs starting.
            session.startBurn()
        }
    }

    public func sharedImageIssue(_ image: DiscImage, for session: BurnSession) -> String? {
        if session.isBusy { return "此设备正在刻录，请等待任务结束。" }
        if session.isLoadingImage || isReserved(session) { return "此设备正在准备镜像。" }
        return BurnPreflight.issue(image: image, device: session.device, options: session.options)
    }

    /// Called only after the user confirms the image, explicit destinations and their options.
    /// All destinations finish preparation before any of them start writing.
    public func startSharedImageBurn(
        image: DiscImage, targetIDs: Set<UUID>, completion: @escaping @MainActor (String?) -> Void
    ) {
        guard !isDemo, !imageCreation.isBusy, sharedPreparation == nil else {
            completion("当前无法准备多机刻录，请等待其他准备任务结束。")
            return
        }
        let targets = sessions.filter { targetIDs.contains($0.id) }
        guard !targets.isEmpty, targets.count == targetIDs.count else {
            completion("请选择需要刻录的设备。")
            return
        }
        for session in targets {
            if let issue = sharedImageIssue(image, for: session) {
                completion("\(label(for: session))：\(issue)")
                return
            }
        }
        let preparation = SharedBurnPreparation(image: image, targets: targets, completion: completion)
        sharedPreparation = preparation
        for session in targets {
            session.selectImage(image.url) { [weak self] success in
                self?.finishSharedPreparation(preparation.id, session: session, success: success)
            }
        }
    }

    public func cancelSharedImageBurn() {
        guard let preparation = sharedPreparation else { return }
        sharedPreparation = nil
        preparation.completion("已取消准备，没有开始写入。")
    }

    private func isReserved(_ session: BurnSession) -> Bool {
        sharedPreparation?.options[session.id] != nil
    }

    private func finishSharedPreparation(_ id: UUID, session: BurnSession, success: Bool) {
        guard let preparation = sharedPreparation, preparation.id == id,
            preparation.remaining.remove(session.id) != nil
        else { return }
        if !success {
            preparation.failure = "\(label(for: session))：\(session.errorMessage ?? "镜像准备已取消。")"
        }
        guard preparation.remaining.isEmpty else { return }
        var requests: [BurnRequest] = []
        for target in preparation.targets {
            guard let request = target.burnRequest,
                request.options == preparation.options[target.id],
                let image = target.image,
                image.url == preparation.image.url,
                image.blocks == preparation.image.blocks,
                image.fileBytes == preparation.image.fileBytes,
                image.tracks == preparation.image.tracks
            else {
                preparation.failure =
                    preparation.failure
                    ?? "\(label(for: target))：\(target.preflightIssue ?? "镜像或选项已改变，请重新确认。")"
                continue
            }
            requests.append(request)
        }
        sharedPreparation = nil
        if let failure = preparation.failure {
            preparation.completion(failure + " 所选设备均未开始写入。")
            return
        }
        startBurns(requests)
        preparation.completion(nil)
    }

    public func cancel() { selectedSession.cancel() }
    public func eject() {
        guard canEditSelectedSession else { return }
        selectedSession.eject()
    }

    public func createImage(to destination: URL) {
        guard !isBusy, !isDemo, !isLoadingImage else { return }
        switch mode {
        case .burn: return
        case .buildISO: imageCreation.build(to: destination)
        case .copyDisc:
            let sourceID = selectedDeviceID
            deviceMonitor.refreshDevices()
            guard selectedDeviceID == sourceID else {
                imageCreation.errorMessage = "来源光驱已断开，请重新选择。"
                return
            }
            if let issue = ImagePreflight.copyIssue(device: selectedDevice) {
                imageCreation.errorMessage = issue
            } else if let device = selectedDevice {
                imageCreation.copyDisc(device, to: destination)
            }
        }
    }

    /// Three independent simulated jobs, including shared and different images; never invokes DRBurn.
    public func startDemo() {
        guard !isBusy, !isLoadingImage, !isDemo else { return }
        mode = .burn
        savedSessions = sessions
        savedDeviceID = selectedDeviceID
        isDemo = true
        sessions = (1...3).map { index in
            let device = DiscDevice(dictionary: [
                "id": "demo-\(index)", "name": "演示刻录机 \(index)", "media": "DVD-R",
                "present": true, "blank": true, "busy": false, "freeBlocks": 2_298_496,
                "canWrite": true, "speeds": [5540.0, 11080.0], "baseSpeed": 1385.0,
                "bufferCapacity": 2_097_152, "underrunProtection": true,
            ])
            let session = BurnSession(engine: makeEngine())
            session.startDemo(
                device: device, imageName: index == 3 ? "Photos-2026.iso" : "Archive-2026.iso", offset: (index - 1) * 8)
            return session
        }
        devices = sessions.compactMap(\.device)
        selectedDeviceID = devices[0].id
    }

    public func exitDemo() {
        guard isDemo, !isBusy else { return }
        sessions = savedSessions
        savedSessions = []
        selectedDeviceID = savedDeviceID
        isDemo = false
        deviceMonitor.refreshDevices()
    }
}

@MainActor
private final class SharedBurnPreparation {
    let id = UUID()
    let image: DiscImage
    let targets: [BurnSession]
    let options: [UUID: BurnOptions]
    let completion: @MainActor (String?) -> Void
    var remaining: Set<UUID>
    var failure: String?

    init(image: DiscImage, targets: [BurnSession], completion: @escaping @MainActor (String?) -> Void) {
        self.image = image
        self.targets = targets
        self.options = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.options) })
        self.remaining = Set(targets.map(\.id))
        self.completion = completion
    }
}
