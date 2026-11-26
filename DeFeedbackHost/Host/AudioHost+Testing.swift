//
//  AudioHost+Testing.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//  Debug-only seams so tests can give a bare host devices and instances without hardware or the plugin.

import Foundation

    #if DEBUG
extension AudioHost {

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
}
#endif
