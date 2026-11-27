//
//  WebErrorStrings.swift
//  DeFeedbackHost
//
//  Every message the web API sends in an error body, in one place. The page and openapi.yaml quote
//  some of these verbatim (OpenAPIConformanceTests checks), so change them deliberately.
//  Moved out of WebControlService.swift without changes (issue #41).
//
import Foundation

// - AI used to refactor/extract these
enum WebErrorStrings: String {

    // MARK: - Service state

    case ServiceDisabled = "Web service is disabled"
    case IncompleteCredentials = "Set both a username and password or turn off Require sign-in."
    case ShuttingDown = "Server is shutting down"
    case IndexPageMissing = "Index page not found."

    // MARK: - Request

    case WrongContentType = "Send a JSON object with Content-Type: application/json"
    case UseGET = "Use GET"
    case UsePOST = "Use POST"
    case UseGETorPOST = "Invlaid HTTP method. Use GET or POST"
    case UseInstanceMethod = "Invalid HTTP method. Use GET, HEAD, PATCH, or DELETE"

    // MARK: - Status failed

    case ExpectedRunning = "Expected {\"running\": true|false}"
    case StartRefused = "Unable to start web host."
    case StartFailed = "The web host failed to start."

    // MARK: - Shutdown

    case ShutdownDisabled = "Shutdown is turned off in the app's settings."
    case ExpectedPhrase = "Expected {\"phrase\": \"<shutdown phrase>\"}"
    case WrongPhrase = "That is not the shutdown phrase."
    case ShutdownNotPermitted = """
        macOS did not allow the shutdown. Allow DeFeedback Host to control System Events in \
        System Settings > Privacy & Security > Automation.
        """

    // MARK: - Devices

    case ExpectedDeviceUIDs = """
        Expected {"input": "<uid>"} and/or {"output": "<uid>"}
        """
    case DevicesLocked = "Stop the host before changing devices."
    case InputMustBeUID = "\"input\" must be a device UID string"
    case OutputMustBeUID = "\"output\" must be a device UID string"

    // MARK: - Sample rates

    case ExpectedSampleRates = "Expected {\"input\": <hz>} and/or {\"output\": <hz>}"
    case SampleRatesLocked = "The host must be stopped before changing sample rates."

    // MARK: - Buffer size

    case ExpectedBufferSize = "Expected {\"bufferSize\": <frames>}"
    case BufferSizeLocked = "The host must be stopped before changing buffer size."

    // MARK: - Instances

    case AddFailed = "Add instance failed."
    case ExpectedSomeSetting = """
        Expected at least one of ["name", "strength", "muted", "bypassed", "inputChannel" \
        or "outputChannel"]
        """
    case NameMustBeString = "\"name\" must be a string"

    // MARK: - Field description suffixes
    //
    // Each completes `fieldMustBe(_:_:)`, so it has to read as the tail of that sentence.

    case BufferSizeDescriptionSuffix = "a valid buffer size of [32, 64, 128, 256, 512, or 1024]"
    case StrengthDescriptionSuffix = "a whole percentage from 0 to 100"
    case ChannelDescriptionSuffix = "a valid 0-based channel number"

    // MARK: - Parameterized errors
    static func pageNotFound(path: String) -> String {
        "Page not found: \(path)"
    }

    static func noDeviceWithUID(_ uid: String, direction: String) -> String {
        "No \(direction) device with UID \"\(uid)\""
    }

    static func bufferSizeNotOffered(_ frames: Int, offered: [Int]) -> String {
        let list = offered.map(String.init).joined(separator: ", ")
        return "\(frames) frames is not valid for the host. The host offers \(list) as valid values."
    }

    static func shutdownFailed(_ reason: String) -> String {
        "The shutdown failed: \(reason)"
    }

    static func noInstance(id text: String) -> String {
        "No instance exists with id \"\(text)\"."
    }

    static func noStrengthParameter(_ displayName: String) -> String {
        "\(displayName) has no parameter 'Strength'."
    }

    static func strengthOutOfRange(_ percent: Int) -> String {
        "\"Strength\" must be an integer from 0 to 100"
    }

    static func rateMustBeHertz(direction: String) -> String {
        "\"\(direction)\" must be a valid sample rate in hertz"
    }

    static func rateMustBePositive(direction: String) -> String {
        "\"\(direction)\" must be a positive sample rate"
    }

    static func noRatesReported(direction: String) -> String {
        "The \(direction) device reports no sample rates."
    }

    static func rateNotOffered(_ requested: Double,
                               direction: String,
                               offered: [Double]) -> String {
        let list = offered.map { String(Int($0)) }.joined(separator: ", ")
        return "\(Int(requested))Hz is not valid for the \(direction) device. Valid values are: \(list)"
    }

    static func fieldMustBe(_ name: String, _ description: WebErrorStrings) -> String {
        "\"\(name)\" must be \(description.rawValue)"
    }

    static func mustBeBoolean(_ name: String) -> String {
        "\"\(name)\" must be true or false"
    }

    static func noChannels(direction: String) -> String {
        "No \(direction) device is selected"
    }

    static func channelOutOfRange(_ name: String,
                                  available: Int,
                                  direction: String) -> String {
        """
        Channel "\(name)" is not available on the \(direction) device.
        Specify a channel between  0 and \(available - 1).
        """
    }
}
