//
//  DeviceSelection+Testing.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//  Debug-only seam so tests can give a bare host fake devices without touching hardware.

#if DEBUG
extension DeviceSelection {

    /// Test seam (debug builds only): gives a bare host something to serve without audio hardware.
    /// Marks the hardware as simulated, so nothing queries or changes real devices for the fakes.
    func setHardwareForTesting(inputDevices: [AudioDevice],
                               outputDevices: [AudioDevice],
                               inputSampleRates: [Double],
                               outputSampleRates: [Double]) {
        self.inputDevices = inputDevices
        self.outputDevices = outputDevices
        self.inputSampleRates = inputSampleRates
        self.outputSampleRates = outputSampleRates
        hardwareIsSimulated = true
    }
}
#endif
