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

enum AudioHostError: LocalizedError {
    case pluginNotInstalled
    case noDeviceSelected
    case microphoneAccessDenied
    case engineUnavailable
    case halComponentUnavailable
    case sampleRateUnavailable(String)
    case sampleRateMismatch(input: Double, output: Double)
    case sampleRateNotApplied(String, Double)
    case bufferSizeNotApplied(String, requested: Int, actual: Int?)
    case maxInstancesReached
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .pluginNotInstalled:
            return String(
                format:String(localized: locKeyErrPluginNotFoundFormat,
                              table: locTableErrors),
                PluginConfiguration.displayName)
        case .noDeviceSelected:
            return String(localized: locKeyErrNoDeviceSelected, table: locTableErrors)
        case .microphoneAccessDenied:
            return String(localized: locKeyErrMicrophoneAccessDenied, table: locTableErrors)
        case .engineUnavailable:
            return String(localized: locKeyErrEngineUnavailable, table: locTableErrors)
        case .halComponentUnavailable:
            return String(localized: locKeyErrHalComponentUnavailableFormat, table: locTableErrors)
        case .sampleRateUnavailable(let name):
            return String(
                format:String(localized: locKeyErrSampleRateUnavailableFormat,
                              table: locTableErrors),
                name)
        case .sampleRateMismatch(let input, let output):
            return String(
                format:String(localized: locKeyErrSampleRateMismatchErrFormat,
                              table: locTableErrors),
                input,
                output
            )
        case .sampleRateNotApplied(let name, let rate):
            return String(
                format:String(localized: locKeyErrSampleRateNotAppliedFormat,
                              table: locTableErrors),
                name,
                rate
            )
        case .bufferSizeNotApplied(let name, let requested, let actual):
            if let actual {
                return String(
                    format:String(localized: locKeyErrBufferSizeNotAppliedFormatActualGiven,
                                  table: locTableErrors),
                    name,
                    requested,
                    actual
                )
            }
            return String(
                format:String(localized: locKeyErrBufferSizeNotAppliedFormatNoActualGiven,
                              table: locTableErrors),
                name,
                requested
            )
        case .maxInstancesReached:
            return String(
                format:String(localized: locKeyErrMaxInstancesReachedFormat,
                              table: locTableErrors),
                PluginConfiguration.maximumInstanceCount)
        case .coreAudio(let what, let status):
            return String(
                format:String(localized: locKeyErrCoreAudioErrFormat,
                          table: locTableErrors),
            status,
            what)
        }
    }
}

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
    init(defaults: UserDefaults = .standard, pluginInstalled: Bool? = nil) {
        self.defaults = defaults
        self.isPluginInstalled = pluginInstalled ?? PluginConfiguration.isInstalled
        self.pluginAvailabilityOverride = pluginInstalled != nil
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

    private(set) var inputDevices: [AudioDevice] = []
    private(set) var outputDevices: [AudioDevice] = []

    enum AudioDirection: CaseIterable {
        case input, output
    }

    /// An audio device that we have seen, but is currently not available, filled by last known values.
    struct UnavailableDevice: Hashable {
        let uid: String
        let name: String
    }

    /// Select device by UID (avoid `AudioDeviceID` because it is ephemeral).
    var selectedInputDeviceUID: String? {
        didSet {
            guard oldValue != selectedInputDeviceUID else { return }
            deviceSelectionChanged(.input)
        }
    }

    var selectedOutputDeviceUID: String? {
        didSet {
            guard oldValue != selectedOutputDeviceUID else { return }
            deviceSelectionChanged(.output)
        }
    }

    /// Remembered name of the previously used input audio device but it is currently not available.
    private(set) var rememberedInputDeviceName: String?
    /// Remembered name of the previously used output audio device but it is currently not available.
    private(set) var rememberedOutputDeviceName: String?

    var selectedInputDevice: AudioDevice? {
        inputDevices.first { $0.uid == selectedInputDeviceUID }
    }

    var selectedOutputDevice: AudioDevice? {
        outputDevices.first { $0.uid == selectedOutputDeviceUID }
    }

    /// the currently selected input audio device ID.  If nil, the device is not available.
    var selectedInputDeviceID: AudioDeviceID? { selectedInputDevice?.id }
    /// the currently selected output audio device ID.  If nil, the device is not available.
    var selectedOutputDeviceID: AudioDeviceID? { selectedOutputDevice?.id }

    /// the currently selected input audio device information when it is not available in the system.
    var unavailableInputDevice: UnavailableDevice? { unavailableDevice(.input) }
    /// the currently selected output audio device information when it is not available in the system.
    var unavailableOutputDevice: UnavailableDevice? { unavailableDevice(.output) }

    func unavailableDevice(_ direction: AudioDirection) -> UnavailableDevice? {
        guard let uid = selectedDeviceUID(direction), selectedDevice(direction) == nil else {
            return nil
        }
        // The name falls back to UID for a session saved before the name was persisted so something is displayed.
        return UnavailableDevice(uid: uid, name: rememberedDeviceName(direction) ?? uid)
    }

    var inputChannelCount: Int { selectedInputDevice?.inputChannelCount ?? 0 }
    var outputChannelCount: Int { selectedOutputDevice?.outputChannelCount ?? 0 }

    func channelCount(for direction: AudioDirection) -> Int {
        switch direction {
        case .input: return inputChannelCount
        case .output: return outputChannelCount
        }
    }

    private func selectedDeviceUID(_ direction: AudioDirection) -> String? {
        switch direction {
        case .input: return selectedInputDeviceUID
        case .output: return selectedOutputDeviceUID
        }
    }

    private func selectedDevice(_ direction: AudioDirection) -> AudioDevice? {
        switch direction {
        case .input: return selectedInputDevice
        case .output: return selectedOutputDevice
        }
    }

    private func rememberedDeviceName(_ direction: AudioDirection) -> String? {
        switch direction {
        case .input: return rememberedInputDeviceName
        case .output: return rememberedOutputDeviceName
        }
    }

    private func rememberDeviceName(_ direction: AudioDirection) {
        let name: String?
        if selectedDeviceUID(direction) == nil {
            name = nil
        } else if let device = selectedDevice(direction) {
            name = device.name
        } else {
            return
        }

        switch direction {
        case .input: rememberedInputDeviceName = name
        case .output: rememberedOutputDeviceName = name
        }
    }

    private func deviceSelectionChanged(_ direction: AudioDirection) {
        rememberDeviceName(direction)
        refreshDeviceCapabilities(direction)
        // because the user changed the selected device, this should invalidate an auto-start.
        resumeWhenDevicesReturn = false
        settingsChanged()
    }

    
    // MARK: - Sample rates

    private(set) var inputSampleRates: [Double] = []
    private(set) var outputSampleRates: [Double] = []

    var selectedInputSampleRate: Double? {
        didSet {
            guard oldValue != selectedInputSampleRate else { return }
            if let rate = selectedInputSampleRate { rememberedInputSampleRate = rate }
            applySampleRate(.input)
            settingsChanged()
        }
    }

    var selectedOutputSampleRate: Double? {
        didSet {
            guard oldValue != selectedOutputSampleRate else { return }
            if let rate = selectedOutputSampleRate { rememberedOutputSampleRate = rate }
            applySampleRate(.output)
            settingsChanged()
        }
    }

    /// The last rate each direction was actually set to, kept across a device's absence (the selected value gets set to `nil` for protection)
    @ObservationIgnored private var rememberedInputSampleRate: Double?
    @ObservationIgnored private var rememberedOutputSampleRate: Double?

    private func rememberedSampleRate(_ direction: AudioDirection) -> Double? {
        switch direction {
        case .input: return rememberedInputSampleRate
        case .output: return rememberedOutputSampleRate
        }
    }

    private func restoreRememberedRate(_ direction: AudioDirection) {
        guard let remembered = rememberedSampleRate(direction),
              deviceID(for: direction) != nil,
              sampleRates(for: direction).contains(where: { Self.ratesMatch($0, remembered) })
        else { return }

        switch direction {
        case .input:
            guard !Self.ratesMatch(selectedInputSampleRate, remembered) else { return }
            selectedInputSampleRate = remembered
        case .output:
            guard !Self.ratesMatch(selectedOutputSampleRate, remembered) else { return }
            selectedOutputSampleRate = remembered
        }
    }

    var doSampleRatesMatch: Bool {
        Self.ratesMatch(selectedInputSampleRate, selectedOutputSampleRate)
    }

    /// Rates are `Double`, and devices report values like 44100.0 that have survived a round trip
    /// through the HAL, so they're compared with a tolerance rather than for equality. Every rate
    /// comparison in the host goes through here: 0.5 Hz swallows that drift while staying far
    /// below the gap between any two real rates (the closest standard pair is 8000 and 11025).
    /// A missing rate matches nothing, including another missing one.
    ///
    ///  - AI caught this for me!
    nonisolated static func ratesMatch(_ first: Double?, _ second: Double?) -> Bool {
        guard let first, let second else { return false }
        return abs(first - second) <= 0.5
    }

    /// Sets which sample rate should be selected in a dropdown, defaulting to first.
    nonisolated static func menuSelection(forCurrent current: Double?,
                                          from rates: [Double]) -> Double? {
        if let current, rates.contains(where: { ratesMatch($0, current) }) {
            return current
        }
        return current ?? rates.first
    }

    /// checks to see if prequisites are satisfied to allow for Audio System start.
    var canStart: Bool {
        isPluginInstalled
            && selectedInputDevice != nil
            && selectedOutputDevice != nil
            && doSampleRatesMatch
            && devicesRejectingBufferSize.isEmpty
    }

    func sampleRates(for direction: AudioDirection) -> [Double] {
        switch direction {
        case .input: return inputSampleRates
        case .output: return outputSampleRates
        }
    }

    private func deviceID(for direction: AudioDirection) -> AudioDeviceID? {
        switch direction {
        case .input: return selectedInputDeviceID
        case .output: return selectedOutputDeviceID
        }
    }

    private func deviceName(for direction: AudioDirection) -> String {
        switch direction {
        case .input:
            return selectedInputDevice?.name ?? rememberedInputDeviceName ?? "input device"
        case .output:
            return selectedOutputDevice?.name ?? rememberedOutputDeviceName ?? "output device"
        }
    }

    /// refreshes what sample rates and buffer sizes are available for the device.
    private func refreshDeviceCapabilities(_ direction: AudioDirection) {
        guard let id = deviceID(for: direction) else {
            setSampleRates([], selection: nil, for: direction)
            setBufferSizeRange(nil, for: direction)
            return
        }

        setBufferSizeRange(AudioHardware.bufferFrameSizeRange(id), for: direction)

        var rates = AudioHardware.availableSampleRates(id)
        let current = AudioHardware.nominalSampleRate(id)

        // If the device doesnt get us a list of rates, at least show the current rate the device is working at
        if rates.isEmpty, let current {
            rates = [current]
        }

        setSampleRates(rates,
                       selection: Self.menuSelection(forCurrent: current, from: rates),
                       for: direction)
    }

    private func setSampleRates(_ rates: [Double], selection: Double?, for direction: AudioDirection) {
        isSyncingSampleRates = true // blocks the system trying to set it back to the old value mid-process
        switch direction {
        case .input:
            inputSampleRates = rates
            selectedInputSampleRate = selection
        case .output:
            outputSampleRates = rates
            selectedOutputSampleRate = selection
        }
        isSyncingSampleRates = false
    }

    private func applySampleRate(_ direction: AudioDirection) {
        guard !isSyncingSampleRates, !isRunning else { return }
        guard let id = deviceID(for: direction),
              let target = direction == .input ? selectedInputSampleRate : selectedOutputSampleRate
        else { return }

        if Self.ratesMatch(AudioHardware.nominalSampleRate(id), target) {
            return
        }

        let name = deviceName(for: direction)
        Task {
            AudioHardware.setNominalSampleRate(target, for: id)
            let applied = await awaitSampleRate(target, on: id)
            if !applied {
                errorMessage = AudioHostError
                    .sampleRateNotApplied(name, target).localizedDescription
                // refresh the options for display
                refreshDeviceCapabilities(direction)
            }
        }
    }
    

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

    private(set) var inputBufferSizeRange: ClosedRange<Int>?
    private(set) var outputBufferSizeRange: ClosedRange<Int>?

    private func setBufferSizeRange(_ range: ClosedRange<Int>?, for direction: AudioDirection) {
        switch direction {
        case .input: inputBufferSizeRange = range
        case .output: outputBufferSizeRange = range
        }
    }

    func bufferSizeRange(for direction: AudioDirection) -> ClosedRange<Int>? {
        switch direction {
        case .input: return inputBufferSizeRange
        case .output: return outputBufferSizeRange
        }
    }

    /// Gets a list of devices that are rejecting the selected buffer size.
    var devicesRejectingBufferSize: [String] {
        var names: [String] = []
        if let device = selectedInputDevice,
           let range = inputBufferSizeRange, !range.contains(bufferSize) {
            names.append(device.name)
        }
        if let device = selectedOutputDevice,
           let range = outputBufferSizeRange, !range.contains(bufferSize) {
            names.append(device.name)
        }
        return names
    }

    
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
    private(set) var runningSampleRate: Double = 0
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

    private(set) var instances: [PluginInstance] = []

    var selectedInstanceIndex = 0 {
        didSet { settingsChanged() }
    }

    var selectedInstance: PluginInstance? {
        instances.indices.contains(selectedInstanceIndex) ? instances[selectedInstanceIndex] : nil
    }

    var canShowPreviousInstance: Bool { selectedInstanceIndex > 0 }
    var canShowNextInstance: Bool { selectedInstanceIndex < instances.count - 1 }

    /// Returns if another instance can be created.  False if plugin is not installed, or we have hit the maxiumum number of istances
    /// (this would be a hard limit due to memory allocation, not an advisory warning due to performance)
    var canAddInstance: Bool {
        isPluginInstalled && instances.count < PluginConfiguration.maximumInstanceCount
    }

    
    // MARK: - Private state

    @ObservationIgnored private var engineController: CoreAudioEngineControl?
    @ObservationIgnored private var io: AudioIO?
    @ObservationIgnored private var deviceMonitor: DeviceListMonitor?

    /// True if the sample rate menus are being updated to match hardware, so their
    /// `didSet` hooks don't try to reset the old value.
    @ObservationIgnored private var isSyncingSampleRates = false

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

    /// Dont try to save settings while `prepare()` is still working so we don't put things in a half-way done state
    @ObservationIgnored private var isRestoring = true

    @ObservationIgnored private var settingsAreDirty = false
    @ObservationIgnored private var lastSavedSettings: HostSettings?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var appTerminationObserver: NSObjectProtocol?

    
    // MARK: - Load State

    func loadApplicationState() async {
        let settings = SettingsStore.load(from: defaults)

        refreshDevices()
        deviceMonitor = DeviceListMonitor { [weak self] in
            self?.refreshDevices()
        }
        watchPluginRegistrations()

        restoreAudioDevicesState(from: settings)
        await restoreInstances(from: settings)

        isRestoring = false
        lastSavedSettings = settings
        startAutosaveTask()
        saveOnTermination()

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
        if let uid = settings.inputDeviceUID {
            rememberedInputDeviceName = settings.inputDeviceName
            selectedInputDeviceUID = uid
        }
        if let uid = settings.outputDeviceUID {
            rememberedOutputDeviceName = settings.outputDeviceName
            selectedOutputDeviceUID = uid
        }

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

        // intentionally setting up sample rate after audio devices so changing audio device doesnt re-set sample rate.
        rememberedInputSampleRate = settings.inputSampleRate
        rememberedOutputSampleRate = settings.outputSampleRate
        for direction in AudioDirection.allCases {
            restoreRememberedRate(direction)
        }
    }

    private func restoreInstances(from settings: HostSettings) async {
        let saved = settings.instances.prefix(PluginConfiguration.maximumInstanceCount)
        guard !saved.isEmpty else { return }

        let names = Self.restoredNames(saved.map(\.name))

        for (persisted, name) in zip(saved, names) {
            let instance = PluginInstance(name: name, changeFlag: changeFlag)
            instance.inputChannel = persisted.inputChannel
            instance.outputChannel = persisted.outputChannel
            instance.isMuted = persisted.isMuted
            instance.isBypassed = persisted.isBypassed
            instances.append(instance)

            await instance.load(restoring: PluginStateCoding.state(from: persisted.pluginState),
                                parameters: persisted.parameterValues)

            if let error = instance.loadError, isPluginInstalled {
                errorMessage = error
            }
        }

        selectedInstanceIndex = min(max(0, settings.selectedInstanceIndex),
                                    max(0, instances.count - 1))
    }


    nonisolated static func restoredNames(_ saved: [String?]) -> [String] {
        var kept: [String?] = []
        for candidate in saved {
            let name = candidate.map(InstanceName.normalized)
            if let name, InstanceName.validate(name, among: kept.compactMap { $0 }) == nil {
                kept.append(name)
            } else {
                kept.append(nil)
            }
        }

        var resolved = kept.compactMap { $0 }
        return kept.map { name in
            if let name { return name }
            let fallback = InstanceName.defaultName(among: resolved)
            resolved.append(fallback)
            return fallback
        }
    }

    
    // MARK: - Save Settings

    private func settingsChanged() {
        guard !isRestoring else { return }
        settingsAreDirty = true
    }

    /// check for settings to save every second.
    private func startAutosaveTask() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.saveIfNeeded()
            }
        }
    }

    private func saveIfNeeded() {
        let instancesAreDirty = changeFlag.consume()

        if instancesAreDirty {
            for instance in instances {
                instance.reconcileMuteFromPlugin()
            }
        }

        guard settingsAreDirty || instancesAreDirty else { return }
        saveSettings()
    }

    func saveSettings() {
        guard !isRestoring else { return }

        let settings = currentSettings()
        settingsAreDirty = false

        guard settings != lastSavedSettings else { return }

        SettingsStore.save(settings, to: defaults)
        lastSavedSettings = settings
    }

    private func currentSettings() -> HostSettings {
        HostSettings(
            pluginIdentity: .configured,
            bufferSize: bufferSize,
            inputDeviceUID: selectedInputDeviceUID,
            outputDeviceUID: selectedOutputDeviceUID,
            inputDeviceName: rememberedInputDeviceName,
            outputDeviceName: rememberedOutputDeviceName,
            inputSampleRate: selectedInputSampleRate ?? rememberedInputSampleRate,
            outputSampleRate: selectedOutputSampleRate ?? rememberedOutputSampleRate,
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


    private func saveOnTermination() {
        appTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settingsAreDirty = true
                self?.saveSettings()
            }
        }
    }

    /// Refreshes the list of devices and their functionalities
    func refreshDevices() {
        let all = AudioHardware.allDevices()
        inputDevices = all.filter { $0.inputChannelCount > 0 }
        outputDevices = all.filter { $0.outputChannelCount > 0 }

        // first run protection
        if selectedInputDeviceUID == nil {
            let preferred = AudioHardware.defaultDeviceID(input: true)
            selectedInputDeviceUID = (inputDevices.first { $0.id == preferred }
                                      ?? inputDevices.first)?.uid
        }
        if selectedOutputDeviceUID == nil {
            let preferred = AudioHardware.defaultDeviceID(input: false)
            selectedOutputDeviceUID = (outputDevices.first { $0.id == preferred }
                                       ?? outputDevices.first)?.uid
        }

        for direction in AudioDirection.allCases {
            rememberDeviceName(direction)
        }

        stopIfDeviceLost()

        // If we're not runing by now, we're still waiting on a missing device
        if !isRunning {
            for direction in AudioDirection.allCases {
                refreshDeviceCapabilities(direction)
                restoreRememberedRate(direction)
            }
        }
        resumeIfDevicesReturned()
    }

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
            try await startAudio()
            isRunning = true
        } catch {
            errorMessage = error.localizedDescription
            teardown()
        }
    }

    func stop() {
        guard isRunning else { return }

        resumeWhenDevicesReturn = false
        teardown()
        isRunning = false

        // natural save state point
        settingsAreDirty = true
        saveSettings()
    }

    private func startAudio() async throws {

        guard isPluginInstalled else {
            throw AudioHostError.pluginNotInstalled
        }

        guard let input = selectedInputDevice, let output = selectedOutputDevice else {
            throw AudioHostError.noDeviceSelected
        }

        // wait for privacy setting in case waiting on user click.
        guard await ensureMicrophoneAccess() else {
            throw AudioHostError.microphoneAccessDenied
        }


        guard let inputRate = selectedInputSampleRate,
              let outputRate = selectedOutputSampleRate else {
            throw AudioHostError.sampleRateUnavailable(output.name)
        }
        guard Self.ratesMatch(inputRate, outputRate) else {
            throw AudioHostError.sampleRateMismatch(input: inputRate, output: outputRate)
        }
        let sampleRate = outputRate


        for direction in AudioDirection.allCases {
            let device = direction == .input ? input : output
            guard let current = AudioHardware.nominalSampleRate(device.id) else {
                throw AudioHostError.sampleRateUnavailable(device.name)
            }
            guard !Self.ratesMatch(current, sampleRate) else { continue }

            AudioHardware.setNominalSampleRate(sampleRate, for: device.id)
            // verify sample rate successfully updated
            guard await awaitSampleRate(sampleRate, on: device.id) else {
                throw AudioHostError.sampleRateNotApplied(device.name, sampleRate)
            }
        }

        let inputFrames = AudioHardware.setBufferFrameSize(bufferSize, for: input.id)
        let outputFrames = AudioHardware.setBufferFrameSize(bufferSize, for: output.id)

        guard let inputFrames, inputFrames == bufferSize else {
            throw AudioHostError.bufferSizeNotApplied(input.name, requested: bufferSize,
                                                      actual: inputFrames)
        }
        guard let outputFrames, outputFrames == bufferSize else {
            throw AudioHostError.bufferSizeNotApplied(output.name, requested: bufferSize,
                                                      actual: outputFrames)
        }

        let maximumFrameCount = bufferSize

        
        // Setup the audio engine
        guard let controller = CoreAudioEngineControl(maximumFrameCount: maximumFrameCount,
                                        inputChannelCount: input.inputChannelCount,
                                        outputChannelCount: output.outputChannelCount,
                                        sampleRate: sampleRate) else {
            throw AudioHostError.engineUnavailable
        }
        self.engineController = controller
        runningSampleRate = sampleRate

        controller.setParallelRendering(
            parallelRendering,
            instanceThreshold: PluginConfiguration.parallelRenderingInstanceThreshold)

        for instance in instances {
            try activateInstance(instance, in: controller)
        }
        controller.primeWithSilence(frameCount: maximumFrameCount * 2)

        // wire up the c++ audio.
        let io = try AudioIO()
        self.io = io
        try io.start(engine: controller,
                     inputDeviceID: input.id,
                     inputChannelCount: input.inputChannelCount,
                     outputDeviceID: output.id,
                     outputChannelCount: output.outputChannelCount,
                     sampleRate: sampleRate,
                     maximumFrameCount: maximumFrameCount)
    }

    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private func awaitSampleRate(_ target: Double,
                                 on device: AudioDeviceID,
                                 timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if Self.ratesMatch(AudioHardware.nominalSampleRate(device), target) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func teardown() {
        // Stop the audio IO
        io?.stop()
        io = nil

        // free plugin instances
        if let engineController {
            for instance in instances {
                if let slot = instance.slot {
                    engineController.retire(slot)
                    engineController.release(slot)
                }
                instance.slot = nil
                instance.teardownRenderResources()
            }
            engineController.setInputUnit(nil)
        }

        engineController = nil
        runningSampleRate = 0
    }


    // MARK: - Instances

    /// Adds an instance and loads the configured audio unit into it.
    ///
    /// - Returns: a new instance, or `nil` if we are capped. An instance whose
    ///   *plugin* failed to load is still returned, but with its `loadError` populated with the reason.
    @discardableResult
    func addInstance() async -> PluginInstance? {
        guard isPluginInstalled else {
            errorMessage = AudioHostError.pluginNotInstalled.localizedDescription
            return nil
        }
        guard canAddInstance else {
            errorMessage = AudioHostError.maxInstancesReached.localizedDescription
            return nil
        }

        let instance = PluginInstance(name: InstanceName.defaultName(among: instances.map(\.name)),
                                      changeFlag: changeFlag)

        let next = instances.count
        instance.inputChannel = inputChannelCount > 0 ? min(next, inputChannelCount - 1) : 0
        instance.outputChannel = outputChannelCount > 0 ? min(next, outputChannelCount - 1) : 0

        instances.append(instance)
        selectedInstanceIndex = instances.count - 1
        settingsChanged()

        await instance.load()

        guard instances.contains(where: { $0 === instance }) else { return nil }

        guard instance.audioUnit != nil else {
            errorMessage = instance.loadError
            return instance
        }

        instance.isMuted = newInstancesMuted
        instance.isBypassed = newInstancesBypassed

        if isRunning, let engineController {
            do {
                try activateInstance(instance, in: engineController)
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        return instance
    }

    func instance(id: UUID) -> PluginInstance? {
        instances.first { $0.id == id }
    }

    /// Looks up an instance by its unique name (case-insensitive, like the uniqueness check).
    func instance(named name: String) -> PluginInstance? {
        instances.first { InstanceName.matches($0.name, name) }
    }

    /// Checks whether `proposed` would be a valid name for `instance`, without renaming it.
    func validateName(_ proposed: String, for instance: PluginInstance) -> InstanceNameError? {
        let others = instances.filter { $0 !== instance }.map(\.name)
        return InstanceName.validate(InstanceName.normalized(proposed), among: others)
    }

    /// Renames an instance with rule checks.
    ///
    /// - Returns: nil on success (or if unchanged), else error reason.
    @discardableResult
    func rename(_ instance: PluginInstance, to proposed: String) -> InstanceNameError? {
        if let error = validateName(proposed, for: instance) {
            return error
        }
        let name = InstanceName.normalized(proposed)
        guard name != instance.name else { return nil }
        instance.name = name
        settingsChanged()
        return nil
    }

    func removeSelectedInstance() {
        remove(at: selectedInstanceIndex)
    }

    /// Removes an instance by instanceId.
    ///
    /// - Returns: false if instance not found, i.e. already deleted
    @discardableResult
    func removeInstance(id: UUID) -> Bool {
        guard let index = instances.firstIndex(where: { $0.id == id }) else { return false }
        remove(at: index)
        return true
    }

    private func remove(at index: Int) {
        guard instances.indices.contains(index) else { return }
        let instance = instances.remove(at: index)

        if index < selectedInstanceIndex {
            selectedInstanceIndex -= 1
        }
        selectedInstanceIndex = min(selectedInstanceIndex, max(0, instances.count - 1))

        settingsChanged()
        retire(instance)
    }


    private func activateInstance(_ instance: PluginInstance, in engine: CoreAudioEngineControl) throws {
        guard let slot = engine.claimSlot() else { throw AudioHostError.maxInstancesReached }

        do {
            try instance.attach(to: engine, slot: slot)
        } catch {
            engine.release(slot)
            throw error
        }
    }

    /// makes sure the instance is out of the render path safely before deleting
    private func retire(_ instance: PluginInstance) {
        instance.stopObservingParameters()

        guard let engineController, let slot = instance.slot else {
            instance.teardownRenderResources()
            return
        }

        engineController.retire(slot)
        instance.slot = nil

        let bufferSeconds = Double(engineController.maximumFrameCount) / max(runningSampleRate, 8_000)
        Task {
            try? await Task.sleep(for: .seconds(bufferSeconds * 2))
            engineController.release(slot)
            instance.teardownRenderResources()
        }
    }

    
    // MARK: - Diagnostics

    struct Diagnostics {
        let captureCycles: UInt64
        let renderCycles: UInt64
        let underruns: UInt64

        /// dsp load is fraction of buffer that is used.  when this maxes we get audio glitches.
        let dspLoad: Double
        let peakDspLoad: Double

        let renderThreadPolicy: RealtimeThreadPolicy?
        let captureThreadPolicy: RealtimeThreadPolicy?

        /// The worker threads. Empty unless parallel rendering is on.
        let workerThreadPolicies: [RealtimeThreadPolicy]

        /// Whether paralell rendering is actually happening, as opposed to being permitted to but
        /// sitting under the instance threshold.
        let parallelRenderingEngaged: Bool

        var hasRendered: Bool { renderCycles > 0 }

        /// Checks if all rendering threads are set to realtime priority
        var audioThreadsAreRealtime: Bool {
            for policy in [renderThreadPolicy, captureThreadPolicy] {
                guard let policy else { continue }
                if !policy.isRealtime { return false }
            }
            return workerThreadPolicies.allSatisfy(\.isRealtime)
        }
    }

    /// Non-zero cycle counts are the difference between "the units started" and "audio is
    /// actually moving". Underruns are the audible symptom of two devices drifting apart.
    ///  - Thanks to AI for giving these meaningful metrics
    var diagnostics: Diagnostics? {
        guard let engineController else { return nil }

        let period = engineController.bufferPeriodNanoseconds
        let smoothed = Double(engineController.smoothedRenderNanoseconds)
        let peak = Double(engineController.peakRenderNanoseconds)

        return Diagnostics(
            captureCycles: engineController.captureCycles,
            renderCycles: engineController.renderCycles,
            underruns: engineController.underruns,
            dspLoad: period > 0 ? smoothed / period : 0,
            peakDspLoad: period > 0 ? peak / period : 0,
            renderThreadPolicy: RealtimeThreadPolicy.read(port: engineController.renderThreadPort),
            captureThreadPolicy: RealtimeThreadPolicy.read(port: engineController.captureThreadPort),
            workerThreadPolicies: engineController.workerThreadPolicies,
            parallelRenderingEngaged: engineController.isParallelRenderingEngaged)
    }

    
    // MARK: - Gallery View Controller

    func showPreviousInstance() {
        selectedInstanceIndex = max(0, selectedInstanceIndex - 1)
    }

    func showNextInstance() {
        selectedInstanceIndex = min(instances.count - 1, selectedInstanceIndex + 1)
    }

}
