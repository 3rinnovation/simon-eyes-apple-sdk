// Android's SipSession in Swift: the same methods, the same
// answers. Each method takes JSON text and returns part 0 of the exit's answer as raw JSON,
// `{"value": ...}` or `{"error": ...}`; a domain refusal is an answer, and only transport and caller
// errors throw. Every call runs on the library's one session thread, "3r-sip", so a session may be
// used and closed from any thread. The rules are the library's: this type copies text and cells in
// and answers out.
import Foundation

/// A Source Input Processor that requires sensing setup: until `setupSensing(_:)` it takes no source
/// and no window.
///
/// Sendable: the handles never change, and the rest of its state (closed, the last fence failure) is
/// behind one lock; every native call runs on the library's session thread.
public final class SipSession: @unchecked Sendable {
    /// The most UTF-8 bytes of one JSON fragment.
    public static let maxFragment = 1 << 20
    /// The most cells of one window: 1 MiB of 32-bit cells.
    public static let maxCells = 1 << 18
    /// The most samples of one batch.
    public static let maxSamples = 1 << 14
    private static let baseGroups = ["builtins", "audio", "runtime", "browser_events"]
    private static let nothing = "{\"value\":null}"
    /// The library's answer to a batch that closed nothing and dropped nothing; read with the first session.
    private static let quiet = Locked<String?>(nil)

    /// The handles.
    let registry: Double
    let processor: Double
    private let state = Locked(State())
    /// Serializes `close()` and `useClock` as Android's synchronized methods: a second close waits
    /// for the first to finish freeing.
    private let monitor = NSRecursiveLock()

    private struct State {
        var closed = false
        /// The last fence failure handed out and its number: one object per failure.
        var failureNumber: Int64 = 0
        var failure: SipError?
    }

    private init(registry: Double, processor: Double) {
        self.registry = registry
        self.processor = processor
    }

    /// A registry with the original runtime's contracts and the named sensor groups
    /// (`device_motion`, `app_interaction`), and a processor of at most 4096 streams.
    /// - Throws: `invalidStep` for an unknown group; nothing made is left behind.
    public static func create(sensorGroups: [String]) throws -> SipSession {
        try make(maxStreams: nil, sensorGroups: sensorGroups)
    }

    /// As `create(sensorGroups:)`, with at most `maxStreams` streams at a time.
    public static func create(maxStreams: Int, sensorGroups: [String]) throws -> SipSession {
        try make(maxStreams: String(maxStreams), sensorGroups: sensorGroups)
    }

    /// `open_session`: the session's arguments, as the original's `openSession`.
    public func openSession(_ argsJson: String) throws -> String {
        try step("open_session", [("args", argsJson)], withRegistry: false)
    }

    /// `sensing_setup`: the law context, consent receipt, plan and device table.
    public func setupSensing(_ setupJson: String) throws -> String {
        try step("sensing_setup", [("setup", setupJson)], withRegistry: true)
    }

    /// `sensing_judge`: the probes; the session holds only the contracts of running signals.
    public func judge(_ judgmentJson: String) throws -> String {
        try fenced("sensing_judge", [("judgment", judgmentJson)])
    }

    /// The clock a collector's samples are measured on, in place of any before; both nil: no fence.
    /// It is read on the library's session thread: a plain read that never blocks and never calls
    /// this library. A throw is the clock's failure (`clock_failed`).
    /// - Throws: `invalidInput` for an id and no clock or the reverse, or an id the session refuses.
    public func useClock(id: String?, now: (@Sendable () throws -> Double)?) throws {
        monitor.lock()
        defer { monitor.unlock() }
        guard (id == nil) == (now == nil) else { throw SipError(.invalidInput, "A clock id and its clock, or neither") }
        if let id { try Self.checkFragment(Self.quote(id)) }
        try onThread {
            try self.open()
            let answer = try Native.answer(Native.useClock(processor: self.processor, id: id, now: now))
            guard Self.isValue(answer) else { throw SipError(.invalidInput, "The session refused the clock: \(answer)") }
        }
    }

    /// The clock id `useClock` set (or a collector's sensor clock), or nil.
    public func clockId() -> String? {
        Native.clockId(processor: processor)
    }

    /// Why a fence after a change did not stand since this was last asked, or nil; asking clears it.
    public func takeFenceFailure() -> SipError? {
        Native.takeFenceFailure(processor: processor).map(failure(of:))
    }

    /// `register_source`: `sensing_not_set_up` until the setup.
    public func registerSource(_ argsJson: String) throws -> String {
        try fenced("register_source", [("args", argsJson)])
    }

    /// `update_capabilities` of one source.
    public func updateCapabilities(sourceId: String, capabilityJson: String) throws -> String {
        try fenced("update_capabilities", [("sourceId", Self.quote(sourceId)), ("args", capabilityJson)])
    }

    /// `process` of an envelope whose samples are in its text; options may be nil.
    public func process(_ inputJson: String, optionsJson: String? = nil) throws -> String {
        var members = [("input", inputJson)]
        if let optionsJson { members.append(("options", optionsJson)) }
        return try step("process", members, withRegistry: true)
    }

    /// `process_window`: an envelope whose samples are the cells (32-bit, little-endian on the wire).
    /// The cells are copied and the copy wiped; the caller's array is not changed.
    public func processWindow(_ envelopeJson: String, optionsJson: String? = nil, cells: [Int32]) throws -> String {
        try Self.checkFragment(envelopeJson)
        if let optionsJson { try Self.checkFragment(optionsJson) }
        guard cells.count <= Self.maxCells else {
            throw SipError(.requestTooLarge, "A window holds at most \(Self.maxCells) cells")
        }
        var bytes = Self.littleEndian(cells)
        return try window("input", input: envelopeJson, options: optionsJson, cells: &bytes)
    }

    /// `open_stream`: a sample stream for one of the session's sources.
    public func openStream(_ streamJson: String) throws -> String {
        try fenced("open_stream", [("stream", streamJson)])
    }

    /// `claim_stream`: collector `holder` (1 to 2^53 - 1) claims the stream of these settings.
    public func claimStream(_ streamJson: String, holder: Int64) throws -> String {
        try step("claim_stream", [("stream", streamJson), ("holder", String(holder))], withRegistry: false)
    }

    /// `release_stream`: whether `holder` was the source's reader, which leaves it unclaimed.
    public func releaseStream(sourceId: String, holder: Int64) throws -> String {
        try step("release_stream", [("sourceId", Self.quote(sourceId)), ("holder", String(holder))], withRegistry: false)
    }

    /// A batch of a stream's samples: times in ms on the stream's clock and three values each in the
    /// contract's units; a time that is not finite reaches the session as `null`, which it refuses.
    /// At most 16,384 samples.
    public func feed(
        sourceId: String, times: [Double], values: [Int32], lost: Bool, flush: Bool, optionsJson: String? = nil
    ) throws -> String {
        guard times.count <= Self.maxSamples, values.count <= 3 * Self.maxSamples else {
            throw SipError(.requestTooLarge, "A batch holds at most \(Self.maxSamples) samples")
        }
        let written = times.map { $0.isFinite ? String(describing: $0) : "null" }.joined(separator: ",")
        var cells = Self.littleEndian(values)
        return try samples(sourceId, times: written, words: "", lost: lost, flush: flush, options: optionsJson, cells: &cells)
    }

    /// A batch of accelerometer readings: times in ns on the sensor's clock and three values each in
    /// m/s². The session converts them. As `feed` otherwise.
    public func feedReadings(
        sourceId: String, timesNanos: [Int64], metresPerSecondSquared: [Float], lost: Bool, flush: Bool,
        optionsJson: String? = nil
    ) throws -> String {
        guard timesNanos.count <= Self.maxSamples, metresPerSecondSquared.count <= 3 * Self.maxSamples else {
            throw SipError(.requestTooLarge, "A batch holds at most \(Self.maxSamples) samples")
        }
        let written = timesNanos.map(String.init).joined(separator: ",")
        var cells = metresPerSecondSquared.flatMap { value -> [UInt8] in
            withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init)
        }
        return try samples(sourceId, times: written, words: ",\"timeUnit\":\"ns\",\"values\":\"m_s2\"", lost: lost,
                           flush: flush, options: optionsJson, cells: &cells)
    }

    /// Whether `close()` was called.
    public var isClosed: Bool { state.read { $0.closed } }

    /// `snapshot`: the sources the session holds.
    public func snapshot() throws -> String {
        try step("snapshot", [], withRegistry: false)
    }

    /// `close_session`; its fences, a wait for one and an unread fence failure go with it.
    public func closeSession() throws -> String {
        try step("close_session", [], withRegistry: false)
    }

    /// Frees the processor and the registry; later calls throw `closed`. Closing twice is allowed.
    public func close() throws {
        try Native.offSessionThread()
        monitor.lock()
        defer { monitor.unlock() }
        let first = state.update { state -> Bool in
            defer { state.closed = true }
            return !state.closed
        }
        guard first else { return }
        // Both are freed whatever the first answers; the first failure is thrown, as Android's finally.
        var failure: (any Error)?
        do { try Self.free("processor", processor) } catch { failure = error }
        do { try Self.free("registry", registry) } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    /// A session that was not closed is closed when released (Android has no such net: close it).
    deinit {
        try? close()
    }

    /// Whether a `feed` answer closed no window and dropped nothing: the one answer a collector need
    /// not pass on. False before any session was made.
    public static func isQuiet(_ answer: String) -> Bool {
        quiet.read { $0 } == answer
    }

    /// `motion_settings`: a collector's settings as the library fills and checks them.
    public static func motionSettings(_ settingsJson: String) throws -> String {
        try Native.loaded()
        return try call("motion_settings", [("settings", settingsJson)])
    }

    /// The text as a JSON string, for the JSON texts this API takes.
    public static func jsonString(_ text: String) -> String {
        quote(text)
    }

    // MARK: - The library's own bridge for DeviceMotion (not an API for hosts)

    /// The native side of collector `holder`.
    func motionRun(holder: UInt64) -> MotionRun {
        MotionRun(session: self, holder: holder)
    }

    /// `motion_start` on this session.
    func motionStart(holder: UInt64, sourceId: String, settings: DeviceMotion.Settings) throws -> String {
        if let options = settings.optionsJson { try Self.checkFragment(options) }
        return try onThread {
            try self.open()
            return try Native.answer(Native.motionStart(
                processor: self.processor, registry: self.registry, holder: holder, sourceId: sourceId,
                settings: settings))
        }
    }

    /// The failure a notice names, `number\tcode\tmessage`: the same object for the same number.
    func failure(of described: String) -> SipError {
        let (number, rest) = SipError.split(described)
        let numbered = Int64(number) ?? 0
        return state.update { state in
            if let kept = state.failure, state.failureNumber == numbered { return kept }
            let made = SipError.kept(rest)
            state.failure = made
            state.failureNumber = numbered
            return made
        }
    }

    // MARK: - Calls

    private static func make(maxStreams: String?, sensorGroups: [String]) throws -> SipSession {
        try Native.loaded()
        try Native.offSessionThread()
        if quiet.read({ $0 }) == nil {
            // Only a value is kept: a refusal stays unread, and the next session asks again.
            let answer = try call("quiet_feed", [])
            if isValue(answer) { quiet.update { $0 = answer } }
        }
        let registry = try handle("registry_new", call("registry_new", []))
        do {
            for group in baseGroups {
                try done(call("install", [("group", quote(group))], a: registry))
            }
            for group in sensorGroups {
                try done(call("install_sensing", [("group", quote(group))], a: registry))
            }
            let made = try call("processor_new", maxStreams.map { [("maxStreams", $0)] } ?? [])
            guard let processor = number(made) else {
                throw SipError(.invalidStep, "Processor refused: \(made)")
            }
            return SipSession(registry: registry, processor: processor)
        } catch {
            try? free("registry", registry)
            throw error
        }
    }

    /// One operation off the session thread: the answer, or the exit's refusal as an error.
    private static func call(_ operation: String, _ members: [(String, String)], a: Double = 0, b: Double = 0) throws -> String {
        try Native.offSessionThread()
        for (_, value) in members { try checkFragment(value) }
        return try Native.answer(Native.operation(operation, members, a: a, b: b, fenced: false))
    }

    private func step(_ operation: String, _ members: [(String, String)], withRegistry: Bool) throws -> String {
        try onThread {
            try self.open()
            return try Self.call(operation, members, a: self.processor, b: withRegistry ? self.registry : 0)
        }
    }

    /// A change, then, with a clock, the fence of what it moved: one call on the session thread.
    private func fenced(_ operation: String, _ members: [(String, String)]) throws -> String {
        try onThread {
            try self.open()
            try Native.offSessionThread()
            for (_, value) in members { try Self.checkFragment(value) }
            return try Native.answer(Native.operation(operation, members, a: self.processor, b: 0, fenced: true))
        }
    }

    /// A stream batch: its text and cells; the cells are wiped whatever happens.
    private func samples(
        _ sourceId: String, times: String, words: String, lost: Bool, flush: Bool, options: String?, cells: inout [UInt8]
    ) throws -> String {
        let text = "{\"sourceId\":\(Self.quote(sourceId)),\"times\":[\(times)]\(words),\"lost\":\(lost),\"flush\":\(flush)}"
        do {
            try Self.checkFragment(text)
            if let options { try Self.checkFragment(options) }
        } catch {
            Native.wipe(&cells)
            throw error
        }
        return try window("samples", input: text, options: options, cells: &cells)
    }

    /// The window of these little-endian cell bytes; they are wiped before this returns. A batch held
    /// while a change has no fence throws `fenceFailed`, the fence's failure its cause.
    private func window(_ name: String, input: String, options: String?, cells: inout [UInt8]) throws -> String {
        defer { Native.wipe(&cells) }
        return try onThread {
            try self.open()
            try Native.offSessionThread()
            let reply = Native.processWindow(
                name, input: input, options: options, cells: &cells, processor: self.processor, registry: self.registry)
            if reply.status == Native.statusFenceFailed {
                let described = String(bytes: reply.part, encoding: .utf8) ?? ""
                let cause = described.isEmpty ? nil : self.failure(of: described)
                throw SipError(.fenceFailed, "A fence did not stand; samples wait for one that does"
                               + (cause.map { ": \($0.message)" } ?? ""), cause: cause)
            }
            return try Native.answer(reply)
        }
    }

    /// A handle freed by a close on another thread meanwhile answers `invalidStep`, which is `closed`.
    private func onThread<T>(_ call: () throws -> T) throws -> T {
        do {
            return try call()
        } catch let failure as SipError where failure.code == .invalidStep && isClosed {
            throw SipError(.closed, "SIP session closed")
        }
    }

    private func open() throws {
        if isClosed { throw SipError(.closed, "SIP session closed") }
    }

    private static func free(_ kind: String, _ handle: Double) throws {
        try done(call("free", [("kind", quote(kind))], a: handle))
    }

    private static func handle(_ operation: String, _ answer: String) throws -> Double {
        guard let number = number(answer) else { throw SipError(.transportFailure, "\(operation) answered \(answer)") }
        return number
    }

    private static func done(_ answer: String) throws {
        guard answer == nothing else { throw SipError(.transportFailure, "Expected \(nothing), got \(answer)") }
    }

    /// The number of `{"value": n}`, read as JSON.
    private static func number(_ answer: String) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any],
              object.count == 1, let value = object["value"] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    /// Whether an answer is the exit's `{"value": ...}`.
    static func isValue(_ answer: String) -> Bool {
        answer.hasPrefix("{\"value\":")
    }

    /// Throws for a JSON fragment over 1 MiB of UTF-8.
    static func checkFragment(_ json: String) throws {
        guard json.utf8.count <= maxFragment else {
            throw SipError(.requestTooLarge, "A JSON fragment holds at most \(maxFragment) UTF-8 bytes")
        }
    }

    /// A JSON string of the text, written by Foundation's encoder (encoding a String does not fail).
    static func quote(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Encoding a String cannot fail.
        guard let data = try? encoder.encode(text), let quoted = String(data: data, encoding: .utf8) else { return "\"\"" }
        return quoted
    }

    private static func littleEndian(_ cells: [Int32]) -> [UInt8] {
        cells.flatMap { cell in withUnsafeBytes(of: cell.littleEndian, Array.init) }
    }
}

/// A value behind a lock, for state several threads read.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func read<T>(_ body: (Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(value)
    }

    @discardableResult
    func update<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
