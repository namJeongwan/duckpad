import DuckpadApplication
import DuckpadPluginRuntimeCore
import DuckpadPluginSupport
import DuckpadWAMRBridge
import Darwin
import Foundation

private final class PluginRuntimeService: NSObject, DuckpadPluginXPCProtocol, @unchecked Sendable {
    private final class Reply: @unchecked Sendable {
        let call: (Data?, String?) -> Void
        init(_ call: @escaping (Data?, String?) -> Void) { self.call = call }
    }
    private static let executionQueue = DispatchQueue(
        label: "com.namjeongwan.duckpad.plugin-runtime.execution",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var isRunning = false
    private var cancellationRequested = false

    func invoke(_ requestFrame: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        stateLock.lock()
        guard !isRunning else {
            stateLock.unlock()
            reply(nil, "plugin runtime connection is already executing")
            return
        }
        isRunning = true
        cancellationRequested = false
        stateLock.unlock()
        let reply = Reply(reply)
        Self.executionQueue.async { [self] in
            dp_wamr_prepare_current()
            stateLock.lock()
            let cancelBeforeExecution = cancellationRequested
            stateLock.unlock()
            if cancelBeforeExecution { dp_wamr_cancel_current() }
            let watchdog = makeWatchdog(for: requestFrame)
            watchdog?.resume()
            let result: Result<Data, any Error>
            do { result = .success(try PluginRuntimeExecutor.responseFrame(for: requestFrame)) }
            catch { result = .failure(error) }
            watchdog?.cancel()
            stateLock.lock()
            isRunning = false
            stateLock.unlock()
            switch result {
            case .success(let frame): reply.call(frame, nil)
            case .failure(let error): reply.call(nil, String(describing: error))
            }
        }
    }

    func cancelCurrent() {
        stateLock.lock()
        let shouldCancel = isRunning
        if shouldCancel { cancellationRequested = true }
        stateLock.unlock()
        guard shouldCancel else { return }
        dp_wamr_cancel_current()
        // WAMR's async trap is cooperative. If a guest is still executing
        // after the grace interval (for example a tight branch loop in the
        // classic interpreter), retire this service cleanly. launchd then
        // supplies a fresh on-demand process without crash-throttling it.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let remainsRunning = self.isRunning
            self.stateLock.unlock()
            if remainsRunning { Darwin._exit(0) }
        }
    }

    private func makeWatchdog(for frame: Data) -> DispatchSourceTimer? {
        guard let request = try? PluginFrameCodec.decode(ExtensionHostRequest.self, from: frame),
              request.limits.isValid else { return nil }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        // The client owns the exact user-visible deadline. This independent
        // grace watchdog guarantees process teardown even if XPC invalidation
        // delivery is delayed while WAMR is executing non-cooperatively.
        timer.schedule(deadline: .now() + .milliseconds(
            Int(request.limits.timeoutMilliseconds) + 100
        ))
        timer.setEventHandler { [weak self] in self?.cancelCurrent() }
        return timer
    }
}

private final class PluginRuntimeListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = PluginRuntimeService()
        connection.exportedInterface = NSXPCInterface(with: DuckpadPluginXPCProtocol.self)
        connection.exportedObject = service
        connection.interruptionHandler = { service.cancelCurrent() }
        connection.invalidationHandler = { service.cancelCurrent() }
        connection.resume()
        return true
    }
}

@main
enum DuckpadPluginRuntimeMain {
    static func main() {
        let listener = NSXPCListener.service()
        let delegate = PluginRuntimeListenerDelegate()
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
