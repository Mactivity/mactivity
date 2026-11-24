import Foundation

/// One long-lived thread that every sampling-side actor runs on (samplers, the snapshot loop,
/// history, alerts).
///
/// The default concurrency pool parks idle threads and the kernel reaps them after about five
/// seconds, which is exactly the idle tick. So every tick was paying to create fresh threads
/// for a dozen actor hops, and that cost more than the sampling. One thread that never exits,
/// with all hops between these actors staying on it, removes both (D-022).
public final class SamplingExecutor: SerialExecutor, @unchecked Sendable {
    public static let shared = SamplingExecutor()

    private let condition = NSCondition()
    // Guarded by `condition`.
    private var jobs: [UnownedJob] = []
    private var thread: Thread?

    private init() {
        let thread = Thread { [unowned self] in run() }
        thread.name = "app.mactivity.sampling"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        condition.lock()
        jobs.append(unowned)
        condition.signal()
        condition.unlock()
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    private func run() {
        while true {
            condition.lock()
            while jobs.isEmpty {
                condition.wait()
            }
            let batch = jobs
            jobs.removeAll(keepingCapacity: true)
            condition.unlock()
            for job in batch {
                job.runSynchronously(on: asUnownedSerialExecutor())
            }
        }
    }
}
