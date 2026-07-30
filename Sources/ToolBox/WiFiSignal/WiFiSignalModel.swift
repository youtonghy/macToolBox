import Combine
import Foundation

@MainActor
final class WiFiSignalModel: ObservableObject {
    @Published private(set) var snapshot: WiFiSnapshot
    @Published private(set) var history: [WiFiHistoryPoint] = []

    private let provider: WiFiSnapshotProviding
    private let sampleInterval: TimeInterval
    private let historyWindow: TimeInterval
    private var started = false
    private var sessionID: UInt64 = 0

    init(
        provider: WiFiSnapshotProviding = CoreWLANWiFiProvider(),
        sampleInterval: TimeInterval = 2,
        historyWindow: TimeInterval = 5 * 60
    ) {
        self.provider = provider
        self.sampleInterval = sampleInterval
        self.historyWindow = historyWindow
        snapshot = .noInterface()
    }

    func start() {
        guard !started else { return }
        started = true
        sessionID &+= 1
        let currentSessionID = sessionID

        provider.onUpdate = { [weak self] snapshot in
            guard let self,
                  self.started,
                  self.sessionID == currentSessionID else {
                return
            }
            self.ingest(snapshot)
        }
        provider.start(interval: sampleInterval)
    }

    func stop() {
        guard started else { return }
        started = false
        sessionID &+= 1
        provider.stop()
        provider.onUpdate = nil
    }

    private func ingest(_ nextSnapshot: WiFiSnapshot) {
        snapshot = nextSnapshot
        let cutoff = nextSnapshot.timestamp.addingTimeInterval(-historyWindow)
        history.removeAll { $0.timestamp < cutoff }
        guard nextSnapshot.state == .connected,
              let rssi = nextSnapshot.rssi,
              let noise = nextSnapshot.noise else {
            return
        }

        history.append(WiFiHistoryPoint(
            timestamp: nextSnapshot.timestamp,
            rssi: rssi,
            noise: noise
        ))
    }
}
