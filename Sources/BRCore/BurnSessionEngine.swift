import DiscBridge
import Foundation

/// One engine per device session; track layouts are never shared between burns.
@MainActor
protocol BurnSessionEngine: AnyObject {
    var onStatus: (@MainActor (BurnSnapshot) -> Void)? { get set }
    func prepareImage(at url: URL, completion: @escaping @MainActor (Result<DiscImage, any Error>) -> Void)
    func start(onDevice identifier: String, options: BurnOptions) throws
    func cancel()
    func eject(_ identifier: String) throws
}

@MainActor
final class NativeBurnSessionEngine: BurnSessionEngine {
    var onStatus: (@MainActor (BurnSnapshot) -> Void)?
    private let engine = BRDiscEngine()

    init() {
        engine.onStatus = { [weak self] dictionary in
            let snapshot = BurnSnapshot(dictionary: dictionary)
            MainActor.assumeIsolated { self?.onStatus?(snapshot) }
        }
    }

    func prepareImage(at url: URL, completion: @escaping @MainActor (Result<DiscImage, any Error>) -> Void) {
        engine.prepareImage(at: url) { dictionary, error in
            let image = dictionary.map { DiscImage(url: url, dictionary: $0) }
            MainActor.assumeIsolated {
                if let error {
                    completion(.failure(error))
                } else if let image {
                    completion(.success(image))
                } else {
                    completion(.failure(CocoaError(.fileReadUnknown)))
                }
            }
        }
    }

    func start(onDevice identifier: String, options: BurnOptions) throws {
        try engine.start(
            onDevice: identifier, speed: options.speed,
            finalize: options.finalize, verify: options.verify, eject: options.eject)
    }

    func cancel() { engine.cancel() }
    func eject(_ identifier: String) throws { try engine.ejectDevice(identifier) }
}
