//
//  BufferSizeRanges.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//  The buffer sizes each selected device accepts. `nil` means unknown (no device selected, or the
//  device would not say), and an unknown range never rejects a size.

import Foundation

struct BufferSizeRanges: Equatable {

    var input: ClosedRange<Int>?
    var output: ClosedRange<Int>?

    func range(for direction: AudioHost.AudioDirection) -> ClosedRange<Int>? {
        switch direction {
        case .input: return input
        case .output: return output
        }
    }

    mutating func set(_ range: ClosedRange<Int>?, for direction: AudioHost.AudioDirection) {
        switch direction {
        case .input: input = range
        case .output: output = range
        }
    }

    /// The names of the devices whose known range does not include `bufferSize`, input first.
    func devicesRejecting(_ bufferSize: Int,
                          input inputDevice: AudioDevice?,
                          output outputDevice: AudioDevice?) -> [String] {
        var names: [String] = []
        if let device = inputDevice, let range = input, !range.contains(bufferSize) {
            names.append(device.name)
        }
        if let device = outputDevice, let range = output, !range.contains(bufferSize) {
            names.append(device.name)
        }
        return names
    }
}
