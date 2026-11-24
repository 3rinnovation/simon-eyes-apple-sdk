// Android's DeviceMotion in Swift: the device's
// accelerometer as one source's sample stream in a SipSession. The library reads the sensor on its own
// thread (Core Motion on iOS), queues the readings and feeds them to the session on its session thread;
// the session cuts the windows and keeps to the sensing judgment.
//
// Swift holds no rule here: the sensor, its queue, the delivery schedule, the fences, the clock and who
// reads a source are the library's. This type is the host's handle on one collector and its delivery
// thread, which hands what the library tells to the listener, in order. Its thread protocol is
// Android's (a model-checked protocol): a run's delivery thread is registered after the native
// start; it hands the notices over in order; a stop waits until it handed over what the stop fed; a
// start that replaced another tells it only after the replaced run's `ended`.
import Foundation

/// What a collector's delivery thread hands back, on that thread; keep each call short. A call that
/// throws is kept for `DeviceMotion.takeDeliveryFailure()` and delivery goes on.
public protocol DeviceMotionListener: AnyObject, Sendable {
    /// The session's answer to a batch that closed a window or dropped something. A batch that did
    /// neither is not passed on, so this is no sign of life.
    func onAnswer(_ answerJson: String) throws
    /// A batch that did not reach the session; the next one says samples were lost.
    func onError(_ error: SipError) throws
    /// A fence after a change did not stand. Until a fence stands again the session refuses samples,
    /// and the collector drops what it read meanwhile; the first batch after says samples were lost.
    func onFenceFailure(_ failure: SipError) throws
    /// The collector stopped without its own `stop`: `"closed"`, the session was closed (on the
    /// delivery thread); `"replaced"`, a newer collector started for the same source of the same
    /// session (on the thread that started the newer one).
    func onStopped(_ reason: String) throws
}

extension DeviceMotionListener {
    public func onError(_ error: SipError) throws {}
    public func onFenceFailure(_ failure: SipError) throws {}
    public func onStopped(_ reason: String) throws {}
}

/// What a collector's calls throw for a misuse or an answer it cannot read (Android's
/// IllegalStateException and IllegalArgumentException).
public enum DeviceMotionError: Error, Sendable, Equatable {
    /// `start()` from a listener: it could wait on a stop elsewhere.
    case startFromListener
    /// The session refused the start (already reading, another clock, the claim or the stream).
    case refused(String)
    /// The library answered in a form this side does not read.
    case unreadAnswer(String)
    /// Settings the library refuses, its word in the answer.
    case settingsRefused(String)
    /// A delivery thread did not hand over in time (kept, not thrown).
    case deliveryDidNotFinish
    /// A start's release of a claim the session kept (kept, not thrown).
    case releaseKept(String)
    /// An argument a collector cannot take (Android's IllegalArgumentException).
    case invalidArgument(String)
}

/// The first failure of a collector's deliveries since it was last asked, with up to 8 later ones.
public final class DeliveryFailure: Error, @unchecked Sendable {
    /// The first.
    public let first: any Error
    /// Up to 8 later ones.
    public private(set) var suppressed: [any Error] = []

    init(_ first: any Error) {
        self.first = first
    }

    func add(_ later: any Error) {
        if suppressed.count < DeviceMotion.maxSuppressed { suppressed.append(later) }
    }
}

/// The device's accelerometer as one source's sample stream in a `SipSession`.
///
/// `start()` sets the session's clock to the sensor's (`apple.uptime`) and opens the stream, so a
/// change that moves this source fences the readings measured before it. Every listener call happens
/// on the delivery thread, one at a time, but `onStopped("replaced")`, which comes on the thread that
/// started the newer collector. `flush()`, `stop(flush:)` and `close()` wait until the delivery thread
/// handed over what they fed, at most 5 s each; from a listener they do not wait. Call `close()` when
/// done: a collector that is never stopped keeps reading.
///
/// Sendable: its mutable state (the current run, the pumps, the claims) is guarded by `lock`, the
/// lifecycle by `lifecycle`, the kept failure by its own lock; the registries are behind locks too.
public final class DeviceMotion: @unchecked Sendable {
    /// The clock of the sensor's timestamps: the uptime clock (`CLOCK_UPTIME_RAW`, Core Motion's), in ms.
    public static let clockId = "apple.uptime"
    /// How long a stop, a flush or a start that replaced another waits for a delivery thread.
    static let waitSeconds: TimeInterval = 5
    /// How long the delivery thread waits for a notice at a time.
    static let noticeWaitMs: UInt64 = 10_000
    /// At most this many later failures are kept in the first one.
    static let maxSuppressed = 8
    /// The key of the delivery threads' mark, where `start()` is refused.
    private static let delivering = "three_r_sip.delivering"
    /// Each collector's number for the session's claims, from 1.
    private static let numbers = Locked<UInt64>(0)
    /// The collectors whose claim the library may still end for a newer collector, by number.
    private static let claiming = Locked<[UInt64: DeviceMotion]>([:])

    private let sip: SipSession
    private let sourceId: String
    private let settings: Settings
    private let listener: any DeviceMotionListener
    /// This collector's number in the session's claims.
    private let number: UInt64
    /// Serializes `start()` and `stop` on the host's threads (not on a delivery thread).
    private let lifecycle = NSRecursiveLock()
    /// Guards the fields below; the delivery threads say on it what they handed over.
    private let lock = NSCondition()
    private let failure = Locked<DeliveryFailure?>(nil)
    /// The run reading, as far as this side knows.
    private var current: Pump?
    /// The delivery threads not yet ended, by run.
    private var pumps: [UInt64: Pump] = [:]
    /// The latest run a start of this collector settled.
    private var settledRun: UInt64 = 0
    /// The claims of this collector the library may still end for a newer collector.
    private var claims = 0

    /// A collector for `sourceId` with these settings, reporting to `listener`.
    /// - Throws: `DeviceMotionError.invalidArgument` for an empty source id.
    public init(session: SipSession, sourceId: String, settings: Settings, listener: any DeviceMotionListener) throws {
        guard !sourceId.isEmpty else { throw DeviceMotionError.invalidArgument("A source id required") }
        sip = session
        self.sourceId = sourceId
        self.settings = settings
        self.listener = listener
        number = Self.numbers.update { value in
            value += 1
            return value
        }
    }

    /// Sets the session's clock, opens the stream and starts reading. A collector already reading the
    /// same source of the same session is replaced: it feeds what it read, stops and hears
    /// `onStopped("replaced")`. False when the device has no accelerometer or the system refused it.
    /// - Throws: `DeviceMotionError.startFromListener` from a listener; `.refused` when already reading,
    ///   when the session holds another clock or refuses the claim or the stream; `.unreadAnswer`.
    @discardableResult
    public func start() throws -> Bool {
        if Thread.current.threadDictionary[Self.delivering] != nil { throw DeviceMotionError.startFromListener }
        let replaced = Replaced()
        defer { replaced.tell() }
        lifecycle.lock()
        defer { lifecycle.unlock() }
        return try begin(replaced)
    }

    /// The collector a start replaced and the run of it the start ended.
    private final class Replaced {
        var holder: UInt64 = 0
        var run: UInt64 = 0

        /// Waits until the replaced collector's delivery thread handed over that run's last batch,
        /// then tells it, on this thread, outside this collector's locks.
        func tell() {
            guard holder != 0, let older = DeviceMotion.claiming.read({ $0[holder] }) else { return }
            if run != 0 && !older.awaitEnded(run) { older.fail(DeviceMotionError.deliveryDidNotFinish) }
            older.unclaim()
            older.tell { try $0.onStopped("replaced") }
        }
    }

    /// One native start, then this run's delivery thread. A start the session refused after
    /// replacing one has stopped it all the same.
    private func begin(_ replaced: Replaced) throws -> Bool {
        // The count and the registry change together, under this collector's lock (Android's).
        lock.lock()
        claims += 1
        Self.claiming.update { $0[number] = self }
        lock.unlock()
        let motion = sip.motionRun(holder: number)
        let answer: String
        do {
            answer = try motion.start(sourceId: sourceId, settings: settings)
        } catch {
            unclaim()
            throw error
        }
        guard let read = StartAnswer(answer) else {
            // Not a form this side reads: whatever the library started stops.
            try? endUnhanded(motion)
            unclaim()
            throw DeviceMotionError.unreadAnswer(answer)
        }
        replaced.holder = read.replaced ?? 0
        replaced.run = read.replacedRun ?? 0
        if let kept = read.kept {
            // The session refused to let the claim go: kept for the host, as any failure of a release.
            fail(motion.refusal("\(kept)\tThe session refused the claim's release"))
        }
        guard let reading = read.reading else {
            unclaim()
            throw DeviceMotionError.refused(answer)
        }
        guard reading else {
            unclaim()
            return false
        }
        let run = motion.run
        let pump = Pump(owner: self, motion: motion, run: run)
        lock.lock()
        current = pump
        pumps[run] = pump
        settledRun = max(settledRun, run)
        lock.broadcast()
        lock.unlock()
        pump.start()
        return true
    }

    /// Stops a run no delivery thread hands over, and takes its notices so none are left waiting.
    private func endUnhanded(_ motion: MotionRun) throws {
        _ = try motion.stop(flush: false)
        Self.takeUntilEnded(motion)
    }

    /// Takes a run's notices up to its end, when no delivery thread does.
    fileprivate static func takeUntilEnded(_ motion: MotionRun) {
        while let notice = try? motion.nextNotice(timeoutMs: 0) {
            if notice.hasSuffix("\tended") { return }
        }
    }

    /// Waits up to 5 s for the delivery thread of `run` to end, or for its start to settle with none.
    private func awaitEnded(_ run: UInt64) -> Bool {
        let deadline = Date(timeIntervalSinceNow: Self.waitSeconds)
        lock.lock()
        defer { lock.unlock() }
        while run > settledRun || pumps[run] != nil {
            if !lock.wait(until: deadline) { return run <= settledRun && pumps[run] == nil }
        }
        return true
    }

    /// One claim of this collector ended: out of the registry when none is left.
    private func unclaim() {
        lock.lock()
        defer { lock.unlock() }
        guard claims > 0 else { return }
        claims -= 1
        if claims == 0 {
            Self.claiming.update { registry in
                if registry[number] === self { registry[number] = nil }
            }
        }
    }

    /// Feeds what is queued now and closes the window in progress; waits for the delivery thread.
    public func flush() throws {
        lock.lock()
        let reading = current
        lock.unlock()
        guard let reading else { return }
        let through = try reading.motion.flush()
        if through >= 0 { reading.await(through) }
    }

    /// Stops reading. With `flush` what is queued is fed and the window in progress closed; without,
    /// what is queued is dropped. Waits for the delivery thread unless called on it.
    public func stop(flush: Bool) throws {
        lock.lock()
        guard let running = current else {
            lock.unlock()
            return
        }
        let onDelivery = running.thread.map { Thread.current === $0 } ?? false
        if onDelivery { current = nil }
        lock.unlock()
        if onDelivery {
            // On the delivery thread the lifecycle lock is not taken: a stop elsewhere may hold it
            // waiting for this thread.
            try end(running, flush: flush)
            return
        }
        lifecycle.lock()
        defer { lifecycle.unlock() }
        lock.lock()
        let ending = current
        current = nil
        lock.unlock()
        if let ending { try end(ending, flush: flush) }
    }

    /// Stops the run natively and waits for its delivery thread to hand over what the stop fed and
    /// its end. A run the library had ended meanwhile is left to whoever ended it to tell.
    private func end(_ ending: Pump, flush: Bool) throws {
        let through: Int64
        do {
            through = try ending.motion.stop(flush: flush)
        } catch {
            // Not stopped: it still reads, so a later stop can stop it.
            lock.lock()
            if current == nil { current = ending }
            lock.unlock()
            throw error
        }
        guard through >= 0 else { return }
        unclaim()
        ending.await(through)
        ending.takeRestIfAbandoned()
    }

    /// Stops without a flush; the session's clock stays set.
    public func close() throws {
        try stop(flush: false)
    }

    /// The first failure a listener call (or the delivery itself) threw since this was last asked,
    /// with up to 8 later ones; or nil.
    public func takeDeliveryFailure() -> DeliveryFailure? {
        failure.update { kept in
            defer { kept = nil }
            return kept
        }
    }

    /// Keeps the first failure until it is taken; up to 8 later ones go into it.
    fileprivate func fail(_ error: any Error) {
        failure.update { kept in
            if let first = kept {
                // The same failure is not kept in itself (Android's).
                if (first.first as AnyObject) !== (error as AnyObject) { first.add(error) }
            } else {
                kept = DeliveryFailure(error)
            }
        }
    }

    /// Calls the listener; what it throws is kept and delivery goes on.
    fileprivate func tell(_ call: (any DeviceMotionListener) throws -> Void) {
        do {
            try call(listener)
        } catch {
            fail(error)
        }
    }

    /// One run's delivery thread: takes the run's notices, in order, and hands each to the listener,
    /// until the run's end.
    fileprivate final class Pump: @unchecked Sendable {
        let motion: MotionRun
        let run: UInt64
        /// The delivery thread: weak, so the thread (which holds this pump until it ends) and the
        /// pump hold no cycle; nil once the thread ended and went.
        private(set) weak var thread: Thread?
        /// Held until `start()`, so the thread is not released before it runs.
        private var unstarted: Thread?
        private unowned let owner: DeviceMotion
        /// The number of the last notice handed over; guarded by the owner's lock.
        private var handedThrough: Int64 = 0
        /// The thread ended; guarded by the owner's lock.
        private var finished = false
        /// It ended at the run's end, every notice handed over; guarded by the owner's lock.
        private var endedWithRun = false

        init(owner: DeviceMotion, motion: MotionRun, run: UInt64) {
            self.owner = owner
            self.motion = motion
            self.run = run
            // The thread holds this pump and the collector until the run ended: a collector that
            // reads is not released under its delivery.
            let collector = owner
            let made = Thread { [self] in self.deliver(collector) }
            made.name = "3r-motion-feed-\(owner.sourceId)"
            thread = made
            unstarted = made
        }

        /// Starts the delivery thread, once.
        func start() {
            let made = unstarted
            unstarted = nil
            made?.start()
        }

        private func deliver(_ collector: DeviceMotion) {
            Thread.current.threadDictionary[DeviceMotion.delivering] = true
            var ended = false
            defer {
                collector.lock.lock()
                finished = true
                endedWithRun = ended
                collector.pumps[run] = nil
                collector.lock.broadcast()
                collector.lock.unlock()
            }
            do {
                while !ended {
                    guard let notice = try motion.nextNotice(timeoutMs: DeviceMotion.noticeWaitMs) else { continue }
                    let (numberText, rest) = SipError.split(notice)
                    // A notice without its number cannot be followed: the pump ends, as Android's.
                    guard let number = Int64(numberText) else { throw DeviceMotionError.unreadAnswer(notice) }
                    ended = handOver(rest)
                    collector.lock.lock()
                    handedThrough = number
                    collector.lock.broadcast()
                    collector.lock.unlock()
                }
            } catch {
                // The library cannot be read: what it tells waits there; a stop still stops it and
                // takes what is left.
                collector.fail(error)
            }
        }

        /// Hands one notice (`kind\t…`) over; whether it was the run's end.
        private func handOver(_ notice: String) -> Bool {
            let (kind, words) = SipError.split(notice)
            switch kind {
            case "answer":
                owner.tell { try $0.onAnswer(words) }
                return false
            case "error":
                let error = motion.refusal(words)
                owner.tell { try $0.onError(error) }
                return false
            case "failure":
                owner.fail(motion.refusal(words))
                return false
            case "fence":
                let failure = motion.fenceFailure(words)
                owner.tell { try $0.onFenceFailure(failure) }
                return false
            case "stopped":
                // The session was closed under it: stopped by itself, its claim gone.
                notReading()
                owner.unclaim()
                owner.tell { try $0.onStopped(words) }
                return false
            case "ended":
                notReading()
                return true
            default:
                owner.fail(DeviceMotionError.unreadAnswer(notice))
                return false
            }
        }

        /// This run no longer reads: a start may begin another.
        private func notReading() {
            owner.lock.lock()
            if owner.current === self { owner.current = nil }
            owner.lock.unlock()
        }

        /// Waits up to 5 s until this thread handed over notice `through`, unless on it; a wait that
        /// ran out is kept as a failure.
        func await(_ through: Int64) {
            if let thread, Thread.current === thread { return }
            let deadline = Date(timeIntervalSinceNow: DeviceMotion.waitSeconds)
            owner.lock.lock()
            defer { owner.lock.unlock() }
            while handedThrough < through && !finished {
                if !owner.lock.wait(until: deadline) {
                    if handedThrough < through && !finished { owner.fail(DeviceMotionError.deliveryDidNotFinish) }
                    return
                }
            }
        }

        /// After a stop: when this thread ended before its run did, takes what is left so none waits.
        func takeRestIfAbandoned() {
            owner.lock.lock()
            let abandoned = finished && !endedWithRun
            owner.lock.unlock()
            if abandoned { DeviceMotion.takeUntilEnded(motion) }
        }
    }

    /// How the collector reads and feeds; filled in and checked by the library when built.
    public struct Settings: Sendable, Equatable {
        /// The windows' length in ms.
        public let windowMs: UInt32
        /// Microseconds between readings asked of the sensor.
        public let samplingPeriodUs: UInt32
        /// How often the queue is fed to the session, in ms.
        public let deliveryMs: UInt32
        /// How many readings the collector's queue holds between deliveries.
        public let queueCapacity: UInt32
        /// Options sent with every batch (the target), or nil.
        public let optionsJson: String?

        /// The library's defaults (windows of 10,000 ms, 25 Hz, a delivery every 1,000 ms) for what
        /// is not set; no options.
        public static func builder() -> Builder {
            Builder()
        }

        /// Builds `Settings`; the library fills in and checks the values in `build()`.
        public struct Builder: Sendable {
            private var windowMs: Int?
            private var samplingPeriodUs: Int?
            private var deliveryMs: Int?
            private var optionsJson: String?

            /// The windows' length in ms.
            public func windowMs(_ ms: Int) -> Builder {
                var next = self
                next.windowMs = ms
                return next
            }

            /// Microseconds between readings.
            public func samplingPeriodUs(_ us: Int) -> Builder {
                var next = self
                next.samplingPeriodUs = us
                return next
            }

            /// How often the queue is fed to the session, in ms.
            public func deliveryMs(_ ms: Int) -> Builder {
                var next = self
                next.deliveryMs = ms
                return next
            }

            /// Options sent with every batch (the target), or nil.
            public func options(_ json: String?) -> Builder {
                var next = self
                next.optionsJson = json
                return next
            }

            /// The settings, the library's defaults for what is not set, each checked there.
            /// - Throws: `DeviceMotionError.settingsRefused` with the library's word
            ///   (window_out_of_range, sampling_period_out_of_range, delivery_out_of_range, in that
            ///   order); `.unreadAnswer`; a `SipError` when the library cannot be used.
            public func build() throws -> Settings {
                var members: [String] = []
                if let windowMs { members.append("\"windowMs\":\(windowMs)") }
                if let samplingPeriodUs { members.append("\"samplingPeriodUs\":\(samplingPeriodUs)") }
                if let deliveryMs { members.append("\"deliveryMs\":\(deliveryMs)") }
                let answer = try SipSession.motionSettings("{" + members.joined(separator: ",") + "}")
                guard let object = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any] else {
                    throw DeviceMotionError.unreadAnswer(answer)
                }
                if let value = object["value"] as? [String: Any] {
                    guard Set(value.keys) == ["windowMs", "samplingPeriodUs", "deliveryMs", "queueCapacity"],
                          let window = Self.whole(value["windowMs"]), let period = Self.whole(value["samplingPeriodUs"]),
                          let delivery = Self.whole(value["deliveryMs"]), let capacity = Self.whole(value["queueCapacity"])
                    else { throw DeviceMotionError.unreadAnswer(answer) }
                    return Settings(windowMs: window, samplingPeriodUs: period, deliveryMs: delivery,
                                    queueCapacity: capacity, optionsJson: optionsJson)
                }
                guard let word = object["error"] as? String else { throw DeviceMotionError.unreadAnswer(answer) }
                throw DeviceMotionError.settingsRefused(word)
            }

            private static func whole(_ value: Any?) -> UInt32? {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == number.doubleValue.rounded(), number.doubleValue >= 0,
                      number.doubleValue <= Double(UInt32.max) else { return nil }
                return number.uint32Value
            }
        }
    }
}
