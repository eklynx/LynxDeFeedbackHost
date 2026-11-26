//
//  WatchedParameter.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/17/26.
//

import AudioToolbox

/// Where one of the plugin's parameters that the host watches lives, and the range it spans.
///
/// The plugin defines its own range, so a percentage the host shows or accepts (the web API speaks
/// 0...100) is always relative to `lowest` and `span`. The conversions are pure and clamp, which
/// keeps a bad value from reaching the plugin.
nonisolated struct WatchedParameter {
    var address: AUParameterAddress?
    var lowest: AUValue = 0
    var span: AUValue = 1

    func percent(of value: AUValue) -> Int {
        Self.percentFromAUValue(of: value, from: lowest, span: span)
    }

    func value(forPercent percent: Int) -> AUValue {
        Self.auValueFromPercent(forPercent: percent, from: lowest, span: span)
    }

    static func percentFromAUValue(of value: AUValue,
                                   from lowest: AUValue,
                                   span: AUValue) -> Int {
        guard span > 0 else { return 0 }
        let fraction = (value - lowest) / span
        return min(100, max(0, Int((fraction * 100).rounded())))
    }

    static func auValueFromPercent(forPercent percent: Int,
                                   from lowest: AUValue,
                                   span: AUValue) -> AUValue {
        let clamped = min(100, max(0, percent))
        return lowest + span * AUValue(clamped) / 100
    }
}
