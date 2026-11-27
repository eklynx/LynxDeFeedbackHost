//
//  PluginConfiguration.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/17/26.
//

import AudioToolbox
import Foundation

nonisolated func stringToOS4Char(_ code: StaticString) -> OSType {
    let bytes = UnsafeBufferPointer(start: code.utf8Start, count: code.utf8CodeUnitCount)
    precondition(bytes.count == 4, "The string must be exactly 4 characters in utf8 encoding.")
    return bytes.reduce(0) { ($0 << 8) | OSType($1) }
}

nonisolated func os4CharToString(_ code: OSType) -> String {
    String((0..<4).reversed().map { shift -> Character in
        let byte = UInt8((code >> (shift * 8)) & 0xFF)
        return (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "?"
    })
}

/// The plugin configuration we care about.  The plugin identifier is:
///     aufx FbTI jDSP  -  Alpha Labs LLC: De-Feedback
nonisolated enum PluginConfiguration {

    static let componentType: OSType = kAudioUnitType_Effect              // 'aufx'
    static let componentSubType: OSType = stringToOS4Char("FbTI")
    static let componentManufacturer: OSType = stringToOS4Char("jDSP")

    static let componentDescription = AudioComponentDescription(
        componentType: componentType,
        componentSubType: componentSubType,
        componentManufacturer: componentManufacturer,
        componentFlags: 0,
        componentFlagsMask: 0)

    // If sandboxed this needs to load out of process.  We hope that sandbox can be turned on once
    // we get an AUv3 version
    static let instantiationOptions: AudioComponentInstantiationOptions = [.loadOutOfProcess]

    static let displayName = "De-Feedback"
    static let pluginHomepage = URL(string: "https://www.alphalabsaudio.com/defeedback/")!

    // Fallback in case the plugin doesn't specify its own `NSHumanReadableCopyright`.
    static let copyrightFallback = "De-Feedback © Alpha Labs LLC."

    static let notInstalledMessage = "The \(displayName) plugin is not installed. Please install it." // TODO: localize string

    static var isInstalled: Bool {
        var description = componentDescription
        return AudioComponentFindNext(nil, &description) != nil
    }

    /// Gets the plugin details, nil if it doesnt exist.
    static var installedPlugin: InstalledPlugin? {
        var description = componentDescription
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }

        var name: Unmanaged<CFString>?
        let fullName = AudioComponentCopyName(component, &name) == noErr
            ? name?.takeRetainedValue() as String?
            : nil

        // Packed version in format where `0xMMMMmmRR` -> `MMMM.mm.RR`
        var packedVersion: UInt32 = 0
        let versionStr = AudioComponentGetVersion(component, &packedVersion) == noErr
            ? "\(packedVersion >> 16).\((packedVersion >> 8) & 0xFF).\(packedVersion & 0xFF)"
            : ""

        return InstalledPlugin(name: fullName ?? displayName,
                               version: versionStr,
                               copyright: bundleCopyright() ?? copyrightFallback)
    }

    struct InstalledPlugin: Equatable {
        let name: String
        let version: String
        let copyright: String
    }

    static let componentDirectories = ["/Library/Audio/Plug-Ins/Components",
                                       NSHomeDirectory() + "/Library/Audio/Plug-Ins/Components"]

    /// Gets the copywrite string for the bundle, nil if it doesnt exist.
    static func bundleCopyright(type: OSType = componentType,
                                subType: OSType = componentSubType,
                                manufacturer: OSType = componentManufacturer,
                                searching directories: [String] = componentDirectories)
    -> String? {
        for directory in directories {
            let entries = (try? FileManager.default
                .contentsOfDirectory(atPath: directory)) ?? []

            for e in entries where e.hasSuffix(".component") {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(e)
                guard let bundle = Bundle(url: url),
                      doesBundleMatch(bundle, type, subType, manufacturer),
                      let copyright = bundle
                        .object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String,
                      !copyright.isEmpty
                else { continue }

                return copyright
            }
        }
        return nil
    }

    /// Checks if the specified bundle matches the criteria we're looking for.
    private static func doesBundleMatch(_ bundle: Bundle,
                                        _ type: OSType,
                                        _ subType: OSType,
                                        _ manufacturer: OSType) -> Bool {
        let bundleDeclaration = bundle.object(forInfoDictionaryKey: "AudioComponents") as? [[String: Any]]
        return bundleDeclaration?.contains { entry in
            entry["type"] as? String == os4CharToString(type)
                && entry["subtype"] as? String == os4CharToString(subType)
                && entry["manufacturer"] as? String == os4CharToString(manufacturer)
        } ?? false
    }

    /// The identity text in the format `auval -a` gives it, i.e. `aufx FbTI jDSP` in our case.
    static var identityDescription: String {
        [componentType, componentSubType, componentManufacturer]
            .map(os4CharToString)
            .joined(separator: " ")
    }

    /// Hard cap, so the engine controller can preallocate its whole slot table up front.  If we need more than this,
    /// you should be looking at a more professional solution.
    static let maximumInstanceCount = 32

    static let validBufferSizes = [32, 64, 128, 256, 512, 1024]

    static let defaultBufferSize = 128

    /// The De-Feedback plugin cannot be set up at 96 kHz or higher with the smallest buffer. Measured
    /// by attaching the real plugin to the engine: at 96 kHz a 32-frame buffer is refused and 64,
    /// 128 and 256 are accepted; at 48 kHz 32 is fine. So from this rate up, the buffer has a floor.
    static let highSampleRateThreshold = 96_000.0
    static let minimumBufferAtHighSampleRate = 64

    /// The smallest buffer the plugin takes at `rate`, or nil when the rate has no floor beyond the
    /// sizes on offer. The 0.5 Hz tolerance is the one every rate comparison in the host uses, so a
    /// rate that round-tripped through the HAL as 95999.7 still counts as 96 kHz.
    static func minimumBufferSize(forSampleRate rate: Double) -> Int? {
        rate >= highSampleRateThreshold - 0.5 ? minimumBufferAtHighSampleRate : nil
    }

    /// The sentence shown when the buffer is below the floor for the rate (in the window next to
    /// Run, in the web API's blocked reason, and when a start is refused).
    static func highSampleRateBufferMessage(bufferSize: Int) -> String {
        "At \(Int(highSampleRateThreshold)) Hz and above the buffer must be at least " // TODO: localize string
            + "\(minimumBufferAtHighSampleRate) samples; it is \(bufferSize)."
    }

    /// Nil when `bufferSize` is fine at `sampleRate` (or there is no rate yet), else the sentence.
    static func bufferSizeProblem(bufferSize: Int, sampleRate: Double?) -> String? {
        guard let sampleRate,
              let minimum = minimumBufferSize(forSampleRate: sampleRate),
              bufferSize < minimum else { return nil }
        return highSampleRateBufferMessage(bufferSize: bufferSize)
    }

    /// How many buffers' worth of slack the I/O ring buffer carries.
    static let ringBufferDepthInBuffers = 8

    /// Number of istances needed before parallel rendering is worth the overhead.
    ///  - Thanks to AI for suggeesting this and measuring where this makes sense.
    ///  TODO: make this an advanced setting so it can be user-set.
    static let parallelRenderingInstanceThreshold = 4
}
