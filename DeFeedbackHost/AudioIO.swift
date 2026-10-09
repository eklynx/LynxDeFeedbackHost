//
//  AudioIO.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/19/26.
//

import AudioToolbox
import CoreAudio

/// Swift side of C++ I/O layer interop (`DFHIO.{h,cpp}`).
final class AudioIO {

    private let handle: DFHIORef

    init() throws {
        guard let handle = dfh_io_create() else {
            throw AudioHostError.engineUnavailable
        }
        self.handle = handle
    }

    deinit {
        dfh_io_destroy(handle)
    }

    var isRunning: Bool { dfh_io_is_running(handle) }

    func start(engine: CoreAudioEngineControl,
               inputDeviceID: AudioDeviceID,
               inputChannelCount: Int,
               outputDeviceID: AudioDeviceID,
               outputChannelCount: Int,
               sampleRate: Double,
               maximumFrameCount: Int) throws {
        var status = dfh_io_start(handle,
                                  engine.engineHandle,
                                  inputDeviceID,
                                  Int32(inputChannelCount),
                                  outputDeviceID,
                                  Int32(outputChannelCount),
                                  sampleRate,
                                  Int32(maximumFrameCount))

        guard status.code == noErr else {
            throw AudioHostError.coreAudio(Self.stage(from: &status), status.code)
        }
    }

    func stop() {
        dfh_io_stop(handle)
    }

    private static func stage(from status: inout DFHIOStatus) -> String {
        withUnsafeBytes(of: &status.stage) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return "starting the audio devices"
            }
            let text = String(cString: base)
            return text.isEmpty ? "starting the audio devices" : text
        }
    }
}
