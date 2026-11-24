// The hosted session's C library, called as three_r_sip_hosted.h says. Every rule is the
// library's; this file copies bytes in, reads replies out and frees them.
import CThreeRSipHosted
import Foundation

/// The C calls, with the copying and freeing the header asks of a caller.
enum Native {
    /// The header's contract version (`THREE_R_SIP_HOSTED_VERSION`).
    static let contractVersion: UInt32 = 1
    /// A batch of samples held while a change has no fence: part 0 is `number\tcode\tmessage`.
    static let statusFenceFailed: UInt32 = 5
    /// The library's own failure (`THREE_R_SIP_STATUS_INTERNAL`).
    static let statusInternal: UInt32 = 4

    /// Nil when the bundled library speaks this contract; read once.
    static let loadFailure: SipError? = contractFailure(version: three_r_sip_hosted_version())

    /// Nil when `version` is this contract's, otherwise the mismatch.
    static func contractFailure(version: UInt32) -> SipError? {
        guard version == contractVersion else {
            return SipError(.abiMismatch, "SIP hosted contract \(contractVersion) required, the library has \(version)")
        }
        return nil
    }

    /// Throws the library's load failure, if any.
    static func loaded() throws {
        if let failure = loadFailure { throw failure }
    }

    /// A call from the session thread itself (a clock calling back) would wait for itself: refused
    /// here, as Android refuses it, before the library would answer `INSIDE_A_CALL`.
    static func offSessionThread() throws {
        if three_r_sip_hosted_on_session_thread() != 0 {
            throw SipError(.transportFailure, "A SIP call from inside a SIP call, which would wait for itself")
        }
    }

    /// A reply's status and part 0; the reply is freed.
    static func take(_ reply: OpaquePointer?) -> (status: UInt32, part: [UInt8]) {
        guard let reply else { return (statusInternal, Array("NULL_REPLY".utf8)) }
        defer { three_r_sip_reply_free(reply) }
        let status = three_r_sip_reply_status(reply)
        let length = three_r_sip_reply_part_length(reply, 0)
        guard let part = three_r_sip_reply_part(reply, 0), length > 0 else { return (status, []) }
        return (status, Array(UnsafeBufferPointer(start: part, count: length)))
    }

    /// Part 0 of an answered reply as text; a refusal as the error Android throws for it.
    static func answer(_ reply: (status: UInt32, part: [UInt8])) throws -> String {
        guard let text = String(bytes: reply.part, encoding: .utf8) else {
            throw SipError(.transportFailure, "Invalid native UTF-8", status: reply.status)
        }
        if reply.status == 0 { return text }
        let code: SipError.Code
        switch text {
        case "NOT_JSON": code = .invalidJson
        case "INVALID_STEP": code = .invalidStep
        default: code = .transportFailure
        }
        throw SipError(code, "SIP transport status \(reply.status): \(text)", status: reply.status)
    }

    /// One operation of the exit on the session thread, its members copied for the call.
    static func operation(
        _ name: String, _ members: [(String, String)], a: Double, b: Double, fenced: Bool
    ) -> (status: UInt32, part: [UInt8]) {
        var bytes: [UInt8] = []
        var places: [(name: Range<Int>, value: Range<Int>)] = []
        for (memberName, value) in members {
            let nameStart = bytes.count
            bytes.append(contentsOf: memberName.utf8)
            let valueStart = bytes.count
            bytes.append(contentsOf: value.utf8)
            places.append((nameStart..<valueStart, valueStart..<bytes.count))
        }
        // One byte more, so the storage has an address even with no members.
        bytes.append(0)
        let operation = Array(name.utf8)
        return bytes.withUnsafeBufferPointer { storage in
            let base = storage.baseAddress!
            let list = places.map { place in
                three_r_sip_member(
                    name: base + place.name.lowerBound, name_length: place.name.count,
                    value: base + place.value.lowerBound, value_length: place.value.count)
            }
            return list.withUnsafeBufferPointer { given in
                operation.withUnsafeBufferPointer { op in
                    take(three_r_sip_hosted_operation(
                        op.baseAddress, op.count, given.baseAddress, given.count, a, b, fenced ? 1 : 0))
                }
            }
        }
    }

    /// A window (`input`) or a stream's batch (`samples`) with its cells; the library zeroes the
    /// cells passed, and this zeroes the caller's array too.
    static func processWindow(
        _ name: String, input: String, options: String?, cells: inout [UInt8], processor: Double, registry: Double
    ) -> (status: UInt32, part: [UInt8]) {
        let nameBytes = Array(name.utf8)
        let inputBytes = Array(input.utf8)
        let optionBytes = options.map { Array($0.utf8) }
        defer { wipe(&cells) }
        return nameBytes.withUnsafeBufferPointer { n in
            inputBytes.withUnsafeBufferPointer { i in
                withOptional(optionBytes) { o, oLength in
                    cells.withUnsafeMutableBufferPointer { c in
                        take(three_r_sip_hosted_process_window(
                            n.baseAddress, n.count, i.baseAddress, i.count, o, oLength,
                            c.baseAddress, c.count, processor, registry))
                    }
                }
            }
        }
    }

    /// The processor's clock, or none: the clock is released by the library exactly once.
    static func useClock(processor: Double, id: String?, now: (@Sendable () throws -> Double)?) -> (status: UInt32, part: [UInt8]) {
        guard let id, let now else {
            return take(three_r_sip_hosted_use_clock(processor, nil, 0, nil, nil, nil))
        }
        let context = Unmanaged.passRetained(ClockBox(now)).toOpaque()
        let idBytes = Array(id.utf8)
        return idBytes.withUnsafeBufferPointer { i in
            // A non-null pointer even for an empty id: the session refuses it, as it should.
            let pointer = i.baseAddress ?? UnsafePointer(bitPattern: 1)
            return take(three_r_sip_hosted_use_clock(processor, pointer, i.count, readClock, context, releaseClock))
        }
    }

    /// `three_r_sip_hosted_clock_id`: the id, or nil for none.
    static func clockId(processor: Double) -> String? {
        let reply = take(three_r_sip_hosted_clock_id(processor))
        guard reply.status == 0, !reply.part.isEmpty else { return nil }
        return String(bytes: reply.part, encoding: .utf8)
    }

    /// `three_r_sip_hosted_take_fence_failure`: `number\tcode\tmessage`, or nil for none.
    static func takeFenceFailure(processor: Double) -> String? {
        let reply = take(three_r_sip_hosted_take_fence_failure(processor))
        guard reply.status == 0, !reply.part.isEmpty else { return nil }
        return String(bytes: reply.part, encoding: .utf8)
    }

    /// `three_r_sip_hosted_motion_start`.
    static func motionStart(
        processor: Double, registry: Double, holder: UInt64, sourceId: String, settings: DeviceMotion.Settings
    ) -> (status: UInt32, part: [UInt8]) {
        var given = three_r_sip_motion_settings(
            size: UInt32(MemoryLayout<three_r_sip_motion_settings>.size),
            window_ms: settings.windowMs, sampling_period_us: settings.samplingPeriodUs,
            delivery_ms: settings.deliveryMs, queue_capacity: settings.queueCapacity)
        let options = settings.optionsJson
        let source = Array(sourceId.utf8)
        let optionBytes = options.map { Array($0.utf8) }
        return source.withUnsafeBufferPointer { s in
            withOptional(optionBytes) { o, oLength in
                take(three_r_sip_hosted_motion_start(
                    processor, registry, holder, s.baseAddress ?? UnsafePointer(bitPattern: 1), s.count, &given, o, oLength))
            }
        }
    }

    /// `three_r_sip_hosted_motion_stop`: the last notice's number, -1 not reading, -2 refused.
    static func motionStop(holder: UInt64, processor: Double, flush: Bool) -> Int64 {
        three_r_sip_hosted_motion_stop(holder, processor, flush ? 1 : 0)
    }

    /// `three_r_sip_hosted_motion_flush`: as `motionStop`, reading on.
    static func motionFlush(holder: UInt64, processor: Double) -> Int64 {
        three_r_sip_hosted_motion_flush(holder, processor)
    }

    /// `three_r_sip_hosted_motion_notice`: `number\tkind\t…`, or nil when none came in time.
    static func motionNotice(run: UInt64, timeoutMs: UInt64) throws -> String? {
        let reply = take(three_r_sip_hosted_motion_notice(run, timeoutMs))
        let text = try answer(reply)
        return text.isEmpty ? nil : text
    }

    /// Zeroes cells the caller's samples were in.
    static func wipe(_ cells: inout [UInt8]) {
        for index in cells.indices { cells[index] = 0 }
    }

    /// `bytes` as a pointer and its length for the call, or NULL and 0.
    private static func withOptional<T>(_ bytes: [UInt8]?, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        guard let bytes else { return body(nil, 0) }
        return bytes.withUnsafeBufferPointer { body($0.baseAddress ?? UnsafePointer(bitPattern: 1), $0.count) }
    }
}

/// A host's clock for the library: read on the session thread; a throw is the clock's failure.
private final class ClockBox: @unchecked Sendable {
    let now: @Sendable () throws -> Double

    init(_ now: @escaping @Sendable () throws -> Double) {
        self.now = now
    }
}

/// `three_r_sip_clock`: writes now in ms and answers 0, or 1 for the clock's failure.
private let readClock: three_r_sip_clock = { context, nowMs in
    guard let context, let nowMs else { return 1 }
    let box = Unmanaged<ClockBox>.fromOpaque(context).takeUnretainedValue()
    guard let now = try? box.now() else { return 1 }
    nowMs.pointee = now
    return 0
}

/// `three_r_sip_release`: gives the clock's context back, once.
private let releaseClock: three_r_sip_release = { context in
    guard let context else { return }
    Unmanaged<ClockBox>.fromOpaque(context).release()
}
