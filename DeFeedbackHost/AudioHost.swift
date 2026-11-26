//
//  AudioHost.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import AVFAudio
import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization
import ServiceManagement
import os

/// Main manger for the host, managing the AUHAL audio devices,  the audio engine, and the plugin instances.
///
/// The I/O layer uses the v2 AUHAL API due to limitations in `AVAudioEngine` and  `AUAudioUnit`
///
/// - AI was used in generating some of the AV engine code, as this required interfacing with a C++ interop layer so we could assign the plugin threads a real-time processing priority.
@Observable
@MainActor
final class AudioHost {

    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameter defaults: defaults to the standard user defaults, can be overridden here for test running purposes.
    /// - Parameter pluginInstalled: overrides the component lookup if the plugin we are hosting is installed.  Used for testing.
    /// - Parameter launchAgents: the launch-at-login / restart-after-crash registration, replaceable for tests.
    /// - Parameter supervision: facts about how this process was started, replaceable for tests.
    init(defaults: UserDefaults = .standard,
         pluginInstalled: Bool? = nil,
         launchAgents: LaunchAgentControlling = LaunchAgentService(),
         supervision: LaunchSupervision = LaunchdSupervision()) {
        self.defaults = defaults
        self.launch = LaunchAgentSettings(agents: launchAgents, supervision: supervision)
        self.persistence = SettingsPersistence(defaults: defaults, changeFlag: changeFlag)
        let instanceList = InstanceList(changeFlag: changeFlag)
        self.instanceList = instanceList
        self.session = EngineSession(instances: instanceList)
        self.isPluginInstalled = pluginInstalled ?? PluginConfiguration.isInstalled
        self.pluginAvailabilityOverride = pluginInstalled != nil

        launch.onError = { [weak self] message in self?.errorMessage = message }
        persistence.host = self
        instanceList.host = self
        session.host = self
        deviceSelection.host = self
    }

    // MARK: - Plugin availability

    /// Whether the configured Audio Unit is registered with the system.
    ///
    /// Cached and kept current by `watchPluginRegistrations()`.
    ///
    /// Read at init rather than in `prepare()` because the tests build a bare `AudioHost` and
    /// never call `prepare()` — a host that claimed the plugin was there until it was asked
    /// would report `canStart` for a start it would then refuse.
    private(set) var isPluginInstalled: Bool

    /// Plugin availbility has been overridden for test purposes.
    @ObservationIgnored private let pluginAvailabilityOverride: Bool

    @ObservationIgnored private var registrationObserver: NSObjectProtocol?

    /// Watch system notification for registered audio components to update cache on plugin state.
    private func watchPluginRegistrations() {
        guard !pluginAvailabilityOverride else { return }

        registrationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(kAudioComponentRegistrationsChangedNotification as String),
            object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPluginInstalled = PluginConfiguration.isInstalled
            }
        }
    }

    // MARK: - Devices
    //
    // Which devices, sample rates and buffer-size ranges are chosen or remembered lives in
    // `DeviceSelection`; the members that forward to it are in `AudioHost+Devices.swift`.

    enum AudioDirection: CaseIterable {
        case input, output
    }

    /// An audio device that we have seen, but is currently not available, filled by last known values.
    struct UnavailableDevice: Hashable {
        let uid: String
        let name: String
    }

    @ObservationIgnored let deviceSelection = DeviceSelection()

    // MARK: - Buffer size

    /// Note: Only changeable while stopped
    var bufferSize = PluginConfiguration.defaultBufferSize {
        didSet { settingsChanged() }
    }

    /// Enable paralell processing.   Note: if the number of instances is below
    /// `PluginConfiguration.parallelRenderingInstanceThreshold`, it will still be serial.
    ///
    /// - Thanks to AI for realizing the benifit of and computing the paralell threshold
    var parallelRendering = true {
        didSet { settingsChanged() }
    }

    /// checks to see if prequisites are satisfied to allow for Audio System start.
    var canStart: Bool {
        isPluginInstalled
            && selectedInputDevice != nil
            && selectedOutputDevice != nil
            && doSampleRatesMatch
            && devicesRejectingBufferSize.isEmpty
    }

    // MARK: - Launch at login and crash restart
    //
    // Two independent launchd agents back these settings; see `LaunchAgentSettings`.

    @ObservationIgnored private let launch: LaunchAgentSettings

    var launchAtLogin: Bool {
        get { launch.launchAtLogin }
        set { launch.launchAtLogin = newValue }
    }

    var restartAfterCrash: Bool {
        get { launch.restartAfterCrash }
        set { launch.restartAfterCrash = newValue }
    }

    var launchPermissionsNeedApproval: Bool { launch.permissionsNeedApproval }
    var needsRelaunchToBeSupervised: Bool { launch.needsRelaunchToBeSupervised }
    func relaunchUnderSupervisor() { launch.relaunchUnderSupervisor() }
    func refreshLaunchAgentStatus() { launch.refreshStatus() }

    // MARK: - Startup and new-instance defaults

    var autoRunOnStartup = false {
        didSet { settingsChanged() }
    }

    var newInstancesMuted = false {
        didSet { settingsChanged() }
    }

    var newInstancesBypassed = false {
        didSet { settingsChanged() }
    }

    // MARK: - Web control endpoint

    var webServerSettings = WebServerSettings() {
        didSet { settingsChanged() }
    }

    // MARK: - ServiceState

    private(set) var isRunning = false
    var runningSampleRate: Double { session.runningSampleRate }
    var errorMessage: String?

    /// Human readable version on why `canStart` is false, or `nil` when nothing is blocking.
    var startBlockedReason: String? {
        if !isPluginInstalled {
            return AudioHostError.pluginNotInstalled.localizedDescription
        }

        // Devices are selected but unavailable
        let missingDeviceName = [unavailableDevice(.input), unavailableDevice(.output)].compactMap { $0 }
        if !missingDeviceName.isEmpty {
            let names = missingDeviceName.map { "\"\($0.name)\"" }.joined(separator: " and ")
            return "\(names) \(missingDeviceName.count == 1 ? "isn't" : "aren't") connected" // TODO: isn't vs aren't will need to go throught localization
        }

        // A device is not selected
        if selectedInputDevice == nil || selectedOutputDevice == nil {
            return "Input and output devices must both be set" // TODO: localize string
        }

        // Sample rate mismatch
        if let inputSampleRate = selectedInputSampleRate,
           let outputSampleRate = selectedOutputSampleRate,
           !doSampleRatesMatch {
            return "Sample rates differ between devices (\(Int(inputSampleRate)) / \(Int(outputSampleRate)) Hz)" // TODO: localize string
        }

        // Some device is not accepting the selected buffer size.
        let bufferSizeRejectingDevices = devicesRejectingBufferSize
        if !bufferSizeRejectingDevices.isEmpty {
            return "\(bufferSizeRejectingDevices.joined(separator: " and ")) won't take a \(bufferSize) sample buffer"  // TODO: localize string
        }
        return nil
    }

    // MARK: - Instances
    //
    // The list, its selection and add/remove/rename live in `InstanceList`; these forward to it.

    @ObservationIgnored private let instanceList: InstanceList

    var instances: [PluginInstance] { instanceList.instances }

    var selectedInstanceIndex: Int {
        get { instanceList.selectedInstanceIndex }
        set { instanceList.selectedInstanceIndex = newValue }
    }

    var selectedInstance: PluginInstance? { instanceList.selectedInstance }
    var canShowPreviousInstance: Bool { instanceList.canShowPrevious }
    var canShowNextInstance: Bool { instanceList.canShowNext }
    var canAddInstance: Bool { instanceList.canAdd }

    @discardableResult
    func addInstance() async -> PluginInstance? { await instanceList.add() }

    func instance(id: UUID) -> PluginInstance? { instanceList.instance(id: id) }
    func instance(named name: String) -> PluginInstance? { instanceList.instance(named: name) }

    func validateName(_ proposed: String, for instance: PluginInstance) -> InstanceNameError? {
        instanceList.validateName(proposed, for: instance)
    }

    @discardableResult
    func rename(_ instance: PluginInstance, to proposed: String) -> InstanceNameError? {
        instanceList.rename(instance, to: proposed)
    }

    func removeSelectedInstance() { instanceList.removeSelected() }

    @discardableResult
    func removeInstance(id: UUID) -> Bool { instanceList.remove(id: id) }

    func showPreviousInstance() { instanceList.showPrevious() }
    func showNextInstance() { instanceList.showNext() }

    #if DEBUG
    /// Test seam (debug builds only): gives a bare host something to serve without audio hardware
    /// or the plugin. Real devices, rates and instances come from `prepare()` and `addInstance()`.
    func setHardwareForTesting(inputDevices: [AudioDevice],
                               outputDevices: [AudioDevice],
                               inputSampleRates: [Double],
                               outputSampleRates: [Double]) {
        deviceSelection.setHardwareForTesting(inputDevices: inputDevices,
                                              outputDevices: outputDevices,
                                              inputSampleRates: inputSampleRates,
                                              outputSampleRates: outputSampleRates)
    }

    /// Test seam (debug builds only): appends an instance that has no plugin loaded behind it, so
    /// it publishes no Strength parameter and has no slot.
    @discardableResult
    func addBareInstanceForTesting(name: String) -> PluginInstance {
        instanceList.addBare(name: name)
    }
    #endif

    // MARK: - Private state

    /// Owns the running engine and its I/O; see `EngineSession`.
    @ObservationIgnored private let session: EngineSession

    /// The engine while audio is running; nil when stopped.
    var liveEngine: CoreAudioEngineControl? { session.engine }
    @ObservationIgnored private var deviceMonitor: DeviceListMonitor?

    /// For the auto-start or device removed/lost case, if true will auto-start the service when the device comes
    /// back online.
    @ObservationIgnored private var resumeWhenDevicesReturn = false

    /// The Task that does the the resume.  A device can have several notifications back to back, so
    /// this makes sure we only try to auto-resume once.
    @ObservationIgnored private var autoResumeTask: Task<Void, Never>?

    /// How long an long to delay the auto-start to make sure it only tries once.
    private static let autoResumeDelay: Duration = .milliseconds(500)

    // MARK: - Persistence state

    /// flag that marks a settings change event.
    @ObservationIgnored let changeFlag = SettingsChangeFlag()

    /// Saves, autosaves and watches `defaults write` edits; see `SettingsPersistence`.
    @ObservationIgnored private let persistence: SettingsPersistence

    // MARK: - Load State

    func loadApplicationState() async {
        let settings = SettingsStore.load(from: defaults)

        refreshLaunchAgentStatus()
        refreshDevices()
        deviceMonitor = DeviceListMonitor { [weak self] in
            self?.refreshDevices()
        }
        watchPluginRegistrations()

        restoreAudioDevicesState(from: settings)
        await instanceList.restore(from: settings)

        persistence.finishRestoring(with: settings)

        await autoRunIfRequested()
    }

    private func autoRunIfRequested() async {
        guard autoRunOnStartup, !isRunning else { return }

        guard canStart else {
            let reason = startBlockedReason ?? "Audio devices aren't ready for an unknown reason" // TODO: localize string

            // check for missing plugin or device missing
            let deviceIsMissing = unavailableDevice(.input) != nil
                || unavailableDevice(.output) != nil
            guard deviceIsMissing, isPluginInstalled else {
                errorMessage = "Auto-run was blocked from starting — \(reason)"
                return
            }

            resumeWhenDevicesReturn = true
            errorMessage = "Auto-run was blocked from starting — \(reason). Restart will be attempted when all devices are back online." // TODO: localize string
            return
        }

        await start()
    }

    private func restoreAudioDevicesState(from settings: HostSettings) {
        deviceSelection.restoreDevices(from: settings)

        if PluginConfiguration.validBufferSizes.contains(settings.bufferSize) {
            bufferSize = settings.bufferSize
        }

        parallelRendering = settings.parallelRendering

        autoRunOnStartup = settings.autoRunOnStartup
        newInstancesMuted = settings.newInstancesStartMuted
        newInstancesBypassed = settings.newInstancesStartBypassed

        var tmpWebSrvSettings = settings.webServer
        tmpWebSrvSettings.port = min(max(tmpWebSrvSettings.port, WebServerSettings.portRange.lowerBound),
                       WebServerSettings.portRange.upperBound)
        webServerSettings = tmpWebSrvSettings

        deviceSelection.restoreSampleRates(from: settings)
    }

    // MARK: - Save Settings

    /// Applies edits made to the individual preference keys (for example `defaults write`).
    func applyExternalPreferences() { persistence.applyExternalPreferences() }

    func settingsChanged() { persistence.markDirty() }

    func saveSettings() { persistence.save() }

    func currentSettings() -> HostSettings {
        HostSettings(
            pluginIdentity: .configured,
            bufferSize: bufferSize,
            inputDeviceUID: selectedInputDeviceUID,
            outputDeviceUID: selectedOutputDeviceUID,
            inputDeviceName: rememberedInputDeviceName,
            outputDeviceName: rememberedOutputDeviceName,
            inputSampleRate: deviceSelection.rateToSave(.input),
            outputSampleRate: deviceSelection.rateToSave(.output),
            parallelRendering: parallelRendering,
            autoRunOnStartup: autoRunOnStartup,
            newInstancesStartMuted: newInstancesMuted,
            newInstancesStartBypassed: newInstancesBypassed,
            selectedInstanceIndex: selectedInstanceIndex,
            instances: instances.map { instance in
                InstanceSettings(
                    name: instance.name,
                    inputChannel: instance.inputChannel,
                    outputChannel: instance.outputChannel,
                    isBypassed: instance.isBypassed,
                    isMuted: instance.isMuted,
                    pluginState: PluginStateCoding.data(from: instance.pluginState),
                    parameterValues: instance.parameterValues)
            },
            webServer: webServerSettings)
    }

    /// Applies preferences read from outside the app. Buffer size and parallel rendering are
    /// locked while running, so `includingLockedWhileRunning` is false then and those wait.
    func apply(_ external: HostPreferences, includingLockedWhileRunning: Bool) {
        if external.autoRunOnStartup != autoRunOnStartup { autoRunOnStartup = external.autoRunOnStartup }
        if external.newInstancesStartMuted != newInstancesMuted { newInstancesMuted = external.newInstancesStartMuted }
        if external.newInstancesStartBypassed != newInstancesBypassed { newInstancesBypassed = external.newInstancesStartBypassed }
        guard includingLockedWhileRunning else { return }
        if external.parallelRendering != parallelRendering { parallelRendering = external.parallelRendering }
        if external.bufferSize != bufferSize { bufferSize = external.bufferSize }
    }

    func reconcileInstancesFromPlugin() {
        for instance in instances {
            instance.reconcileMuteFromPlugin()
        }
    }

    /// Refreshes the list of devices and their functionalities
    func refreshDevices() {
        deviceSelection.refreshDeviceList()

        stopIfDeviceLost()

        // If we're not runing by now, we're still waiting on a missing device
        if !isRunning {
            deviceSelection.refreshAllCapabilities()
        }
        resumeIfDevicesReturned()
    }

    /// The chosen device changed, so an automatic restart waiting on the old choice no longer applies.
    func deviceSelectionDidChange() { resumeWhenDevicesReturn = false }

    private func stopIfDeviceLost() {
        guard isRunning,
              let lost = unavailableDevice(.input) ?? unavailableDevice(.output) else { return }

        stop()
        resumeWhenDevicesReturn = true
        errorMessage = """
            Stopped — "\(lost.name)" was disconnected. \
            The host will start again when it's reconnected.
            """ // TODO: localize string
    }

    private func resumeIfDevicesReturned() {
        guard resumeWhenDevicesReturn, !isRunning, canStart, autoResumeTask == nil else { return }

        autoResumeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autoResumeDelay)
            guard let self else { return }

            self.autoResumeTask = nil

            // recheck right before start in case device is lost again (i.e. bad cable)
            guard self.resumeWhenDevicesReturn, !self.isRunning, self.canStart else { return }

            self.resumeWhenDevicesReturn = false
            await self.start()
        }
    }

    // MARK: - Run / Stop

    func toggleRunning() async {
        if isRunning { stop() } else { await start() }
    }

    func start() async {
        guard !isRunning else { return }
        errorMessage = nil
        do {
            try await session.start()
            isRunning = true
        } catch {
            errorMessage = error.localizedDescription
            session.teardown()
        }
    }

    func stop() {
        guard isRunning else { return }

        resumeWhenDevicesReturn = false
        session.teardown()
        isRunning = false

        // Buffer size / parallel rendering edits made via `defaults write` while running were held back.
        applyExternalPreferences()

        // natural save state point
        persistence.saveNow()
    }

    /// What `EngineSession` reads at each stage of starting.
    func engineStartSettings() -> EngineStartSettings {
        EngineStartSettings(pluginInstalled: isPluginInstalled,
                            input: selectedInputDevice,
                            output: selectedOutputDevice,
                            inputRate: selectedInputSampleRate,
                            outputRate: selectedOutputSampleRate,
                            bufferSize: bufferSize,
                            parallelRendering: parallelRendering)
    }

    // MARK: - Diagnostics

    typealias Diagnostics = EngineDiagnostics

    var diagnostics: Diagnostics? { session.diagnostics }
}
