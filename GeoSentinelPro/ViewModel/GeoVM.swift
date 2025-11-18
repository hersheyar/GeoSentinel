
import Foundation
import CoreLocation
import Combine

@MainActor
final class GeoVM: NSObject, ObservableObject {
    // MARK: Published state
    @Published var regions: [GeoRegion] = []
    @Published var settings = GeoSettings()
    @Published var authStatusDescription: String = "Unknown"
    @Published var preciseEnabled: Bool = true
    @Published var logs: [LogEntry] = []
    @Published var presence: [UUID: RegionRuntimeState] = [:]

    // MARK: Timers (per region)
    private var dwellTimers: [UUID: Task<Void, Never>] = [:]
    private var exitTimers:  [UUID: Task<Void, Never>] = [:]

    private var cancellables: Set<AnyCancellable> = []
    private let location = LocationService.shared

    // Notification tokens for cleanup
    private var notifTokens: [NSObjectProtocol] = []

    override init() {
        super.init()
        location.delegate = self

        // Observe actionable notification callbacks; hop to MainActor
        let t1 = NotificationCenter.default.addObserver(forName: .gsSnooze15, object: nil, queue: .main) { [weak self] n in
            guard let idStr = n.object as? String, let uuid = UUID(uuidString: idStr) else { return }
            Task { @MainActor [weak self] in
                self?.snooze(regionID: uuid, minutes: 15)
            }
        }
        let t2 = NotificationCenter.default.addObserver(forName: .gsDone, object: nil, queue: .main) { [weak self] n in
            guard let idStr = n.object as? String, let uuid = UUID(uuidString: idStr) else { return }
            Task { @MainActor [weak self] in
                self?.log("DONE tapped for region \(uuid).")
            }
        }
        notifTokens = [t1, t2]
    }

    deinit {
        for t in notifTokens { NotificationCenter.default.removeObserver(t) }
        notifTokens.removeAll()
    }

    // MARK: Bootstrap / Persistence
    func bootstrap() async {
        regions  = Persistence.load([GeoRegion].self, key: StoreKeys.regions, default: [])
        settings = Persistence.load(GeoSettings.self, key: StoreKeys.settings, default: GeoSettings())
        presence = Persistence.load([UUID: RegionRuntimeState].self, key: StoreKeys.runtime,  default: [:])

        await updateMonitoringMode()
        log("Bootstrap complete. Regions: \(regions.count). Mode: \(settings.batteryMode.title).")
        requestAuthIfNeeded()
    }

    func save() {
        Persistence.save(regions,  key: StoreKeys.regions)
        Persistence.save(settings, key: StoreKeys.settings)
        Persistence.save(presence, key: StoreKeys.runtime)
    }

    // MARK: Auth
    func requestAuthIfNeeded() { location.requestWhenInUse() }
    func upgradeToAlways()     { location.requestAlways() }

    // MARK: CRUD
    func addRegion(_ r: GeoRegion) {
        regions.append(r)
        presence[r.id] = RegionRuntimeState()
        save()
        Task { await updateMonitoringMode() }
        log("Added region: \(r.name) (\(Int(r.radius)) m).")
    }

    func updateRegion(_ r: GeoRegion) {
        guard let idx = regions.firstIndex(where: { $0.id == r.id }) else { return }
        regions[idx] = r
        save()
        Task { await updateMonitoringMode() }
        log("Updated region: \(r.name).")
    }

    func deleteRegion(_ id: UUID) {
        if let idx = regions.firstIndex(where: { $0.id == id }) {
            let r = regions.remove(at: idx)
            cancelTimers(for: id)
            presence[id] = nil
            save()
            Task { await updateMonitoringMode() }
            log("Deleted region: \(r.name).")
        }
    }

    func toggleEnabled(_ id: UUID) {
        guard let idx = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[idx].enabled.toggle()
        save()
        Task { await updateMonitoringMode() }
        log("Toggled \(regions[idx].name) to \(regions[idx].enabled ? "enabled" : "disabled").")
    }

    func toggleBatteryMode() {
        settings.batteryMode = settings.batteryMode == .saver ? .highFidelity : .saver
        save()
        Task { await updateMonitoringMode() }
        log("Battery mode: \(settings.batteryMode.title).")
    }

    // MARK: Monitoring Strategy
    func updateMonitoringMode() async {
        // Stop all first
        for r in location.monitoredRegions() {
            if let c = r as? CLCircularRegion { location.stopMonitoring(region: c) }
        }
        location.stopSignificant()
        location.stopVisits()

        // Determine which regions to monitor (≤ 20)
        let enabled = regions.filter { $0.enabled }
        let capped = Array(enabled.prefix(min(settings.maxMonitored, 20)))
        for r in capped {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude),
                radius: clampRadius(r.radius),
                identifier: r.id.uuidString
            )
            region.notifyOnEntry = r.notifyOnEntry
            region.notifyOnExit  = r.notifyOnExit
            location.startMonitoring(region: region)
            location.requestState(for: region) // seed presence after relaunch/enable
        }

        switch settings.batteryMode {
        case .saver:
            location.startSignificant()
            location.startVisits()
        case .highFidelity:
            break
        }
    }

    private func clampRadius(_ rad: Double) -> Double {
        if rad < 50 {
            log("Warning: radius \(Int(rad))m is small—clamped to 50 m for reliability.")
            return 50
        }
        if rad > 2000 {
            log("Warning: radius \(Int(rad))m exceeds 2000—clamped.")
            return 2000
        }
        return rad
    }

    // MARK: State + Helpers
    private func state(for id: UUID) -> RegionRuntimeState { presence[id] ?? RegionRuntimeState() }
    private func setState(_ s: RegionRuntimeState, for id: UUID) { presence[id] = s; save() }
    private func region(for id: UUID) -> GeoRegion? { regions.first(where: { $0.id == id }) }

    private func cancelTimers(for id: UUID) {
        dwellTimers[id]?.cancel(); dwellTimers[id] = nil
        exitTimers[id]?.cancel();  exitTimers[id]  = nil
    }

    private func isSnoozed(_ id: UUID) -> Bool {
        if let until = presence[id]?.snoozedUntil { return until > Date() }
        return false
    }

    func snooze(regionID: UUID, minutes: Int) {
        var s = state(for: regionID)
        s.snoozedUntil = Date().addingTimeInterval(Double(minutes) * 60)
        setState(s, for: regionID)
        log("Snoozed \(prettyName(regionID)) for \(minutes) min.")
    }

    private func log(_ message: String) {
        logs.insert(LogEntry(message: message), at: 0)
        if logs.count > 500 { logs.removeLast(logs.count - 500) }
        Persistence.save(logs, key: StoreKeys.logs)
    }

    private func prettyName(_ id: UUID) -> String {
        if let r = region(for: id) { return "\(r.name) [\(id.uuidString.prefix(6))]" }
        return id.uuidString
    }

    // MARK: Dwell / Debounce core
    func handleEnterRaw(id: UUID) {
        var s = state(for: id)
        s.lastEnterRaw = Date()
        setState(s, for: id)
        log("RAW ENTER for \(prettyName(id)). Starting dwell \(settings.dwellSeconds)s…")

        // Cancel exit debounce; start dwell
        exitTimers[id]?.cancel(); exitTimers[id] = nil

        dwellTimers[id]?.cancel()
        let dwell = settings.dwellSeconds
        dwellTimers[id] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, dwell)) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if !self.isSnoozed(id) {
                await self.confirmEnter(id: id)
            } else {
                self.log("ENTER suppressed by Snooze for \(self.prettyName(id)).")
            }
        }
    }

    func handleExitRaw(id: UUID) {
        var s = state(for: id)
        s.lastExitRaw = Date()
        setState(s, for: id)
        log("RAW EXIT for \(prettyName(id)). Debouncing \(settings.exitDebounceSeconds)s…")

        // Cancel dwell; start exit debounce
        dwellTimers[id]?.cancel(); dwellTimers[id] = nil

        let wait = settings.exitDebounceSeconds
        exitTimers[id]?.cancel()
        exitTimers[id] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait)) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self.confirmExit(id: id)
        }
    }

    private func confirmEnter(id: UUID) async {
        var s = state(for: id)
        if s.presence == .inside {
            log("ENTER already confirmed for \(prettyName(id)); skipping.")
            return
        }
        s.lastConfirmedEnter = Date()
        s.presence = .inside
        setState(s, for: id)
        cancelTimers(for: id)

        if let r = region(for: id), r.notifyOnEntry {
            NotificationService.shared.postGeofence(
                title: "Entered \(r.name)",
                body: "at \(Date().formatted(date: .omitted, time: .standard))",
                userInfo: ["regionID": r.id.uuidString]
            )
        }
        log("✅ ENTERED \(prettyName(id))")
    }

    private func confirmExit(id: UUID) async {
        var s = state(for: id)
        if s.presence == .outside {
            log("EXIT already confirmed for \(prettyName(id)); skipping.")
            return
        }
        s.lastConfirmedExit = Date()
        s.presence = .outside
        setState(s, for: id)
        cancelTimers(for: id)

        if let r = region(for: id), r.notifyOnExit {
            NotificationService.shared.postGeofence(
                title: "Exited \(r.name)",
                body: "at \(Date().formatted(date: .omitted, time: .standard))",
                userInfo: ["regionID": r.id.uuidString]
            )
        }
        log("⬜️ EXITED \(prettyName(id))")
    }
}

// MARK: - LocationServiceDelegate (file scope)
extension GeoVM: LocationServiceDelegate {
    func didChangeAuth(status: CLAuthorizationStatus, precise: Bool) {
        preciseEnabled = precise
        switch status {
        case .authorizedAlways:      authStatusDescription = "Always"
        case .authorizedWhenInUse:   authStatusDescription = "When In Use"
        case .denied:                authStatusDescription = "Denied"
        case .restricted:            authStatusDescription = "Restricted"
        case .notDetermined:         authStatusDescription = "Not Determined"
        @unknown default:            authStatusDescription = "Unknown"
        }
        log("Auth=\(authStatusDescription), Precise=\(precise)")
        Task { await updateMonitoringMode() }
    }

    func didEnter(region: CLRegion) {
        guard let uuid = UUID(uuidString: region.identifier) else { return }
        handleEnterRaw(id: uuid)
    }

    func didExit(region: CLRegion) {
        guard let uuid = UUID(uuidString: region.identifier) else { return }
        handleExitRaw(id: uuid)
    }

    func didVisit(_ visit: CLVisit) {
        log("Visit: arrival=\(visit.arrivalDate), departure=\(visit.departureDate)")
    }

    func didUpdateSignificant(_ location: CLLocation) {
        log("Significant change @ \(location.coordinate.latitude),\(location.coordinate.longitude)")
    }

    func didFail(_ error: Error) {
        log("Location error: \(error.localizedDescription)")
    }

    func didDetermineState(_ state: CLRegionState, for region: CLRegion) {
        guard let uuid = UUID(uuidString: region.identifier) else { return }
        var s = self.state(for: uuid)
        switch state {
        case .inside:  s.presence = .inside
        case .outside: s.presence = .outside
        case .unknown: s.presence = .unknown
        @unknown default: s.presence = .unknown
        }
        setState(s, for: uuid)
        log("Region state = \(s.presence.rawValue.capitalized) for \(prettyName(uuid)).")
    }
}
