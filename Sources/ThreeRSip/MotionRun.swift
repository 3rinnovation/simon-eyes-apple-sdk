// The native side of one DeviceMotion collector:
// the library's own bridge between DeviceMotion and the Rust collector, not an API for hosts. The
// collector reads its sensor, keeps its queue and delivers on the library's session thread; this
// type only starts and stops it and takes what it tells, one notice at a time.
import Foundation

// Sendable: its state is the run number behind a lock; the session is Sendable.
final class MotionRun: @unchecked Sendable {
    let session: SipSession
    /// The collector's number in the session's claims.
    let holder: UInt64
    /// The running start's number (its notices' mailbox), 0 before a start that reads.
    private let current = Locked<UInt64>(0)

    init(session: SipSession, holder: UInt64) {
        self.session = session
        self.holder = holder
    }

    /// The run a start that reads began, 0 before one.
    var run: UInt64 { current.read { $0 } }

    /// Starts reading: `{"value":{"reading":…,"replaced":…,"kept":…,"run":…,"replacedRun":…}}` or the
    /// session's refusal `{"error":…,"replaced":…,"kept":…,"replacedRun":…}`.
    func start(sourceId: String, settings: DeviceMotion.Settings) throws -> String {
        let answer = try session.motionStart(holder: holder, sourceId: sourceId, settings: settings)
        // The run is taken from any answer that names one, read or not, as Android finds it: a run
        // whose answer is not read is still stopped and its notices taken.
        if let run = StartAnswer.run(in: answer) {
            current.update { $0 = run }
        }
        return answer
    }

    /// Stops reading, the last batch fed and the window closed when `flush`: the number of the last
    /// notice this posted, -1 when it was not reading.
    func stop(flush: Bool) throws -> Int64 {
        try Native.offSessionThread()
        return try through(Native.motionStop(holder: holder, processor: session.processor, flush: flush))
    }

    /// Feeds what is queued and closes the window in progress: as `stop`, reading on.
    func flush() throws -> Int64 {
        try Native.offSessionThread()
        return try through(Native.motionFlush(holder: holder, processor: session.processor))
    }

    /// The next notice, `number\tkind\t…`, waiting at most `timeoutMs`; nil when none came.
    func nextNotice(timeoutMs: UInt64) throws -> String? {
        let run = self.run
        guard run != 0 else { return nil }
        return try Native.motionNotice(run: run, timeoutMs: timeoutMs)
    }

    /// The session's one object for the fence failure a `fence` notice names.
    func fenceFailure(_ numberCodeMessage: String) -> SipError {
        session.failure(of: numberCodeMessage)
    }

    /// What an `error` or `failure` notice (`code\tmessage`) or a start's `kept` word names.
    func refusal(_ codeMessage: String) -> SipError {
        SipError.kept(codeMessage)
    }

    /// -2 is the library's refusal of a collector it does not know: not reading, as Android's JNI
    /// answers it (-1). A call from the session thread was refused before (`offSessionThread`).
    private func through(_ number: Int64) throws -> Int64 {
        number == -2 ? -1 : number
    }
}

/// A start's answer, read as strictly as Android's patterns: `{"value":{"reading":b,"replaced":n|null,
/// "kept":"w"|null,"run":n|null,"replacedRun":n|null}}` or `{"error":"w","replaced":n|null,"kept":"w"|null,
/// "replacedRun":n|null}`, those members only, numbers whole and not negative.
struct StartAnswer {
    /// Nil for a refusal.
    let reading: Bool?
    let replaced: UInt64?
    let kept: String?
    let run: UInt64?
    let replacedRun: UInt64?

    init?(_ answer: String) {
        guard let object = Self.object(answer) else { return nil }
        if let value = object["value"] as? [String: Any] {
            guard object.count == 1, Set(value.keys) == ["reading", "replaced", "kept", "run", "replacedRun"],
                  let reading = Self.boolean(value["reading"]),
                  let replaced = Self.number(value["replaced"]), let kept = Self.word(value["kept"]),
                  let run = Self.number(value["run"]), let replacedRun = Self.number(value["replacedRun"])
            else { return nil }
            (self.reading, self.replaced, self.kept, self.run, self.replacedRun) = (reading, replaced, kept, run, replacedRun)
        } else if object["error"] is String, Set(object.keys) == ["error", "replaced", "kept", "replacedRun"],
                  let replaced = Self.number(object["replaced"]), let kept = Self.word(object["kept"]),
                  let replacedRun = Self.number(object["replacedRun"]) {
            (self.reading, self.replaced, self.kept, self.run, self.replacedRun) = (nil, replaced, kept, nil, replacedRun)
        } else {
            return nil
        }
    }

    /// The run an answer names, read or not (Android's `"run":(\\d{1,19})` found anywhere).
    static func run(in answer: String) -> UInt64? {
        guard let value = object(answer)?["value"] as? [String: Any], let run = number(value["run"]) else { return nil }
        return run
    }

    private static func object(_ answer: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String: Any]
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A whole, not negative number, or null as nil wrapped (`.some(nil)`); anything else is unread.
    private static func number(_ value: Any?) -> UInt64?? {
        if value is NSNull { return .some(nil) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double >= 0, double == double.rounded(), double < 18_446_744_073_709_551_616 else { return nil }
        return .some(number.uint64Value)
    }

    /// A word, or null as nil wrapped.
    private static func word(_ value: Any?) -> String?? {
        if value is NSNull { return .some(nil) }
        guard let text = value as? String else { return nil }
        return .some(text)
    }
}
