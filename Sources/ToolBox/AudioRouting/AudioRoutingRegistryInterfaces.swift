import Combine

@MainActor
protocol AudioProcessRegistryProviding: AnyObject {
    var snapshot: [AudioProcessSnapshot] { get }
    var snapshotPublisher: AnyPublisher<[AudioProcessSnapshot], Never> { get }
    var lastErrorPublisher: AnyPublisher<String?, Never> { get }

    func start()
    func stop()
    func refreshAfterAudioServerRestart()
}

@MainActor
protocol AudioDeviceRegistryProviding: AnyObject {
    var snapshot: [AudioOutputDevice] { get }
    var defaultOutputUID: String? { get }
    var rememberedUIDs: Set<String> { get set }
    var snapshotPublisher: AnyPublisher<[AudioOutputDevice], Never> { get }
    var defaultOutputPublisher: AnyPublisher<String?, Never> { get }
    var lastErrorPublisher: AnyPublisher<String?, Never> { get }
    var serviceGenerationPublisher: AnyPublisher<Int, Never> { get }
    var routeGenerationPublisher: AnyPublisher<Int, Never> { get }

    func start()
    func stop()
    func refreshAfterAudioServerRestart()
}

extension AudioProcessRegistry: AudioProcessRegistryProviding {
    var snapshotPublisher: AnyPublisher<[AudioProcessSnapshot], Never> {
        $snapshot.eraseToAnyPublisher()
    }

    var lastErrorPublisher: AnyPublisher<String?, Never> {
        $lastError.eraseToAnyPublisher()
    }

    func refreshAfterAudioServerRestart() {
        stop()
        start()
    }
}

extension AudioDeviceRegistry: AudioDeviceRegistryProviding {
    var snapshotPublisher: AnyPublisher<[AudioOutputDevice], Never> {
        $snapshot.eraseToAnyPublisher()
    }

    var defaultOutputPublisher: AnyPublisher<String?, Never> {
        $defaultOutputUID.eraseToAnyPublisher()
    }

    var lastErrorPublisher: AnyPublisher<String?, Never> {
        $lastError.eraseToAnyPublisher()
    }

    var serviceGenerationPublisher: AnyPublisher<Int, Never> {
        $serviceGeneration.eraseToAnyPublisher()
    }

    var routeGenerationPublisher: AnyPublisher<Int, Never> {
        $routeGeneration.eraseToAnyPublisher()
    }

    func refreshAfterAudioServerRestart() {
        stop()
        start()
    }
}
