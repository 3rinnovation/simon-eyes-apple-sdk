// What the Swift API throws: Android's SipException with the
// same codes. A class: a fence failure is one object per numbered failure, as Android keeps it.
import Foundation

/// A transport or caller error of the Source Input Processor. A domain refusal is an answer
/// (`{"error": ...}`), not this.
public final class SipError: Error, @unchecked Sendable, CustomStringConvertible {
    /// Android's `SipException.Code`, named alike.
    public enum Code: String, Sendable, CaseIterable {
        /// A missing argument where text or cells are required.
        case invalidInput = "INVALID_INPUT"
        /// A JSON fragment that is not one whole JSON value.
        case invalidJson = "INVALID_JSON"
        /// Text that is not valid Unicode (never from a Swift `String`).
        case invalidUtf16 = "INVALID_UTF16"
        /// A fragment over 1 MiB of UTF-8, more than 262,144 cells or 16,384 samples.
        case requestTooLarge = "REQUEST_TOO_LARGE"
        /// An unknown sensor group, or a processor the core refused to make.
        case invalidStep = "INVALID_STEP"
        /// A call after `SipSession.close()`.
        case closed = "CLOSED"
        /// The bundled native library could not be used.
        case nativeLoadFailed = "NATIVE_LOAD_FAILED"
        /// The bundled native library speaks another contract version.
        case abiMismatch = "ABI_MISMATCH"
        /// The native call failed or answered what the transport cannot read.
        case transportFailure = "TRANSPORT_FAILURE"
        /// Samples while the last fence did not stand; the cause is the fence's failure.
        case fenceFailed = "FENCE_FAILED"
    }

    /// What went wrong.
    public let code: Code
    /// In words.
    public let message: String
    /// The native reply's status, when one answered.
    public let status: UInt32?
    /// What caused it: a fence's failure for `fenceFailed`.
    public let cause: (any Error)?

    init(_ code: Code, _ message: String, status: UInt32? = nil, cause: (any Error)? = nil) {
        self.code = code
        self.message = message
        self.status = status
        self.cause = cause
    }

    public var description: String { "\(code.rawValue): \(message)" }

    /// A failure the native side kept, `code\tmessage`, as Android reads it: a clock's failure is
    /// `invalidInput`, a code this type names keeps it, anything else is `transportFailure`.
    static func kept(_ described: String) -> SipError {
        let (word, message) = split(described)
        let code: Code
        if word == "clock_failed" || word == "invalid_clock_value" {
            code = .invalidInput
        } else {
            code = Code(rawValue: word) ?? .transportFailure
        }
        return SipError(code, message)
    }

    /// `word\trest` as its two parts; no tab: the whole as the word.
    static func split(_ text: String) -> (String, String) {
        guard let tab = text.firstIndex(of: "\t") else { return (text, "") }
        return (String(text[..<tab]), String(text[text.index(after: tab)...]))
    }
}
