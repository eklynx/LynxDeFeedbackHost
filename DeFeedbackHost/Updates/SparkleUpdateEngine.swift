//
//  SparkleUpdateEngine.swift
//  DeFeedbackHost
//
//  The ONLY file that imports Sparkle. Implements `UpdateEngine` (see UpdateChecking.swift).
//
//  Sparkle is configured never to act on its own (Info.plist: SUEnableAutomaticChecks=NO,
//  SUAutomaticallyUpdate=NO). Background probes use `checkForUpdateInformation()`, which reports
//  through the delegate without UI. Only `presentUpdate()` shows Sparkle's flow.
//
import AppKit
import Foundation
import Sparkle

@MainActor
final class SparkleUpdateEngine: NSObject, UpdateEngine {

    private var controller: SPUStandardUpdaterController?
    private var configurationError: String?
    private var pending: [@MainActor (ProbeResult) -> Void] = []
    private var foundVersion: String?
    private let willRelaunch: @MainActor () -> Void

    /// - Parameter willRelaunch: called just before Sparkle quits to install and relaunch, so the
    ///   caller can release the single-instance lock for the new process.
    init(willRelaunch: @escaping @MainActor () -> Void) {
        self.willRelaunch = willRelaunch
        super.init()
    }

    /// Sparkle is created on first use, not at launch: a second launch that bows out to the running
    /// copy, or a user who never enables updates, never starts it.
    private func prepare() {
        guard controller == nil, configurationError == nil else { return }

        // A build without a signing key can never verify an update. Say so instead of letting
        // Sparkle raise its own "contact the developer" alert.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            configurationError = "Updates aren't configured in this build (no signing key)."
            return
        }

        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: self,
                                                      userDriverDelegate: nil)
        do {
            try controller.updater.start()
            self.controller = controller
        } catch {
            configurationError = "Couldn't start the updater: \(error.localizedDescription)"
        }
    }

    func probe(onResult: @escaping @MainActor (ProbeResult) -> Void) {
        prepare()
        if let configurationError {
            onResult(.failed(configurationError))
            return
        }
        guard let updater = controller?.updater else {
            onResult(.failed("The updater isn't running."))
            return
        }
        // Coalesce: a probe or a user-facing session is already in flight.
        pending.append(onResult)
        guard pending.count == 1 else { return }
        guard updater.canCheckForUpdates else {
            finish(.failed("An update check is already in progress."))
            return
        }
        foundVersion = nil
        updater.checkForUpdateInformation()
    }

    func presentUpdate() {
        prepare()
        guard let controller else {
            // No Sparkle: the best we can do is send the user to the releases page.
            NSWorkspace.shared.open(UpdateLinks.releasesPage)
            return
        }
        controller.checkForUpdates(nil)
    }

    private func finish(_ result: ProbeResult) {
        let callbacks = pending
        pending = []
        callbacks.forEach { $0(result) }
    }
}

// MARK: - SPUUpdaterDelegate

extension SparkleUpdateEngine: SPUUpdaterDelegate {

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        // Sparkle calls its delegate on the main thread; assuming that keeps events in order.
        MainActor.assumeIsolated { self.foundVersion = version }
    }

    nonisolated func updater(_ updater: SPUUpdater,
                             didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: (any Error)?) {
        // Only silent probes report here with `.updateInformation`; user-initiated sessions are
        // Sparkle's to present and need no result from us.
        guard updateCheck == .updateInformation else { return }
        let nsError = error as NSError?
        let isNoUpdate = nsError?.domain == SUSparkleErrorDomain
            && nsError?.code == Int(SUError.noUpdateError.rawValue)
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let version = self.foundVersion {
                self.finish(.updateAvailable(version: version))
            } else if error == nil || isNoUpdate {
                self.finish(.upToDate)
            } else {
                self.finish(.failed(message ?? "Unknown error"))
            }
        }
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // Synchronous on purpose: the app is about to quit, a Task might never run.
        MainActor.assumeIsolated { self.willRelaunch() }
    }
}
