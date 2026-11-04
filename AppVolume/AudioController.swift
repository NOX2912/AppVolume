import AppKit
import CoreAudio
import Observation
import os

/// Eine App, die gerade Audio ausgibt (für die Anzeige).
struct AudioApp: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage
    var volume: Double
    var muted: Bool
}

@MainActor @Observable
final class AudioController {
    private(set) var apps: [AudioApp] = []
    private(set) var outputDeviceName = ""
    private(set) var permission = AudioPermission.state
    private(set) var lastError: String?

    /// Alle Audio-Prozesse einer App, auch wenn sie gerade nichts ausgeben.
    private struct Group {
        let identity: AppIdentity
        var processObjects: [AudioObjectID] = []
        var isRunningOutput = false
    }

    @ObservationIgnored private var groups: [String: Group] = [:]
    @ObservationIgnored private var taps: [String: ProcessTap] = [:]
    @ObservationIgnored private var identities: [pid_t: AppIdentity] = [:]
    @ObservationIgnored private var processListeners: [AudioObjectID: PropertyListener] = [:]
    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var outputDevice: AudioDeviceID?
    @ObservationIgnored private var outputUID: String?
    @ObservationIgnored private let store = VolumeStore()
    @ObservationIgnored private let log = Logger(subsystem: "io.github.nox2912.AppVolume", category: "audio")
    @ObservationIgnored private var fallbackTimer: Timer?

    init() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices] {
            if let listener = PropertyListener(object: system, selector: selector, handler: { [weak self] in
                self?.scheduleRefresh()
            }) {
                systemListeners.append(listener)
            }
        }
        // Sicherheitsnetz, falls ein Listener-Ereignis verloren geht.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        if permission == .unknown {
            AudioPermission.request { [weak self] _ in
                self?.permission = AudioPermission.state
                self?.refresh()
            }
        }
        refresh()
    }

    // MARK: Bedienung

    func setVolume(_ volume: Double, for id: String) {
        let volume = min(max(volume, 0), 1)
        store.setVolume(volume, for: id)
        if let i = apps.firstIndex(where: { $0.id == id }) { apps[i].volume = volume }
        syncTaps()
    }

    func toggleMute(_ id: String) {
        let muted = !store.isMuted(id)
        store.setMuted(muted, for: id)
        if let i = apps.firstIndex(where: { $0.id == id }) { apps[i].muted = muted }
        syncTaps()
    }

    func recheckPermission() {
        permission = AudioPermission.state
        refresh()
    }

    // MARK: Prozessliste

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        updateOutputDevice()

        let objects = CA.processObjects()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Listener für IsRunningOutput pflegen
        let current = Set(objects)
        for gone in processListeners.keys where !current.contains(gone) {
            processListeners[gone] = nil
        }
        for object in objects where processListeners[object] == nil {
            processListeners[object] = PropertyListener(object: object, selector: kAudioProcessPropertyIsRunningOutput) {
                [weak self] in self?.scheduleRefresh()
            }
        }

        var newGroups: [String: Group] = [:]
        var livePIDs = Set<pid_t>()
        for object in objects {
            guard let pid = CA.pid(of: object), pid > 0, pid != ownPID else { continue }
            livePIDs.insert(pid)
            let identity = identities[pid] ?? AppResolver.resolve(pid: pid, bundleID: CA.bundleID(of: object))
            identities[pid] = identity
            newGroups[identity.key, default: Group(identity: identity)].processObjects.append(object)
            if CA.isRunningOutput(object) {
                newGroups[identity.key]?.isRunningOutput = true
            }
        }
        identities = identities.filter { livePIDs.contains($0.key) }
        for key in newGroups.keys { newGroups[key]?.processObjects.sort() }
        groups = newGroups

        let newApps = groups.values
            .filter(\.isRunningOutput)
            .map { group in
                AudioApp(id: group.identity.key, name: group.identity.name, icon: group.identity.icon,
                         volume: store.volume(for: group.identity.key), muted: store.isMuted(group.identity.key))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if newApps != apps { apps = newApps }

        syncTaps()
    }

    private func updateOutputDevice() {
        let device = CA.defaultOutputDevice()
        outputDevice = device
        outputUID = device.flatMap(CA.deviceUID)
        let name = device.flatMap(CA.name) ?? "Kein Ausgabegerät"
        if name != outputDeviceName { outputDeviceName = name }
    }

    // MARK: Taps

    /// Wahrnehmungsnahe Kurve: 50 % am Regler ≈ halb so laut empfunden.
    private func gain(for key: String) -> Float {
        if store.isMuted(key) { return 0 }
        let v = Float(store.volume(for: key))
        return v * v
    }

    /// Hält für jede App mit Lautstärke < 100 % (oder stumm) genau einen passenden Tap aktiv.
    /// Taps bleiben bestehen, solange die App Audio-Prozesse hat – so gibt es beim erneuten
    /// Abspielen keinen kurzen Moment in voller Lautstärke.
    private func syncTaps() {
        guard permission != .denied, let outputDevice, let outputUID else {
            removeAllTaps()
            return
        }
        for key in taps.keys where groups[key] == nil {
            taps.removeValue(forKey: key)?.invalidate()
        }
        var errors: [String] = []
        for (key, group) in groups {
            let gain = gain(for: key)
            guard gain < 0.9999 else {
                taps.removeValue(forKey: key)?.invalidate()
                continue
            }
            if let tap = taps[key], tap.processObjects == group.processObjects, tap.outputUID == outputUID {
                tap.setGain(gain)
                continue
            }
            taps.removeValue(forKey: key)?.invalidate()
            do {
                taps[key] = try ProcessTap(processObjects: group.processObjects, outputDevice: outputDevice,
                                           outputUID: outputUID, name: group.identity.name, gain: gain)
                log.info("Tap für \(group.identity.name, privacy: .public) erstellt")
            } catch {
                log.error("Tap für \(group.identity.name, privacy: .public): \(String(describing: error), privacy: .public)")
                errors.append("\(group.identity.name): \(error)")
            }
        }
        let message = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if message != lastError { lastError = message }
    }

    private func removeAllTaps() {
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
    }

    func shutdown() {
        removeAllTaps()
    }
}
