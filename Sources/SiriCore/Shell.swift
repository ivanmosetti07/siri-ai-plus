import Darwin
import Foundation

/// Comandi nella shell di login con un gruppo di processi proprio: al timeout o all'annullamento
/// si ferma tutto l'albero (anche i figli di `codex` o `claude`), e l'uscita si legge riga per riga.
public enum Shell {
    /// Al massimo 4 comandi insieme: niente thread bloccati a decine.
    private static let gate = AsyncGate(limit: 4)

    public struct Result: Sendable {
        public let status: Int32
        public let output: String
    }

    /// - Parameter onLine: riceve ogni riga appena arriva (per lo streaming).
    public static func run(_ command: String, timeout: Double = 600, input: URL? = nil,
                           onLine: (@Sendable (String) -> Void)? = nil) async -> Result {
        guard !Task.isCancelled else { return Result(status: -SIGTERM, output: "Comando annullato.") }
        await gate.enter()
        defer { Task { await gate.leave() } }
        guard !Task.isCancelled else { return Result(status: -SIGTERM, output: "Comando annullato.") }
        let job = Job(command: command, input: input, onLine: onLine)
        return await withTaskCancellationHandler {
            await job.start(timeout: timeout)
        } onCancel: {
            job.kill()
        }
    }

    /// Processo lungo (server di sviluppo): parte subito, si ferma con `stop()`, l'uscita arriva riga per riga.
    public final class Background: @unchecked Sendable {
        private let job: Job
        public let finished: Task<Result, Never>

        public init(_ command: String, onLine: @escaping @Sendable (String) -> Void) {
            let job = Job(command: command, input: nil, onLine: onLine)
            self.job = job
            finished = Task.detached { await job.start(timeout: 24 * 3600) }
        }

        public func stop() { job.kill() }
    }

    /// Stringa sicura tra apici singoli per zsh.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    final class Job: @unchecked Sendable {
        let command: String
        let input: URL?
        let onLine: (@Sendable (String) -> Void)?
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var finished = false
        private var cancelled = false

        init(command: String, input: URL?, onLine: (@Sendable (String) -> Void)?) {
            self.command = command; self.input = input; self.onLine = onLine
        }

        func kill() {
            lock.lock(); cancelled = true; let pid = self.pid; let done = finished; lock.unlock()
            guard pid > 0, !done else { return }
            Darwin.kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { Darwin.kill(-pid, SIGKILL) }
        }

        func start(timeout: Double) async -> Result {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: self.execute(timeout: timeout)) }
            }
        }

        private func execute(timeout: Double) -> Result {
            lock.lock(); let stopped = cancelled; lock.unlock()
            guard !stopped else { return Result(status: -SIGTERM, output: "Comando annullato.") }
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { return Result(status: -1, output: "pipe non disponibile") }
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
            posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
            posix_spawn_file_actions_addclose(&actions, fds[0])
            if let input { posix_spawn_file_actions_addopen(&actions, 0, input.path, O_RDONLY, 0) }
            else { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Gruppo di processi nuovo: kill(-pid) raggiunge anche i figli.
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attributes, 0)
            let args = ["/bin/zsh", "-lc", command]
            var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            var child: pid_t = 0
            let spawned = posix_spawn(&child, "/bin/zsh", &actions, &attributes, &argv, environ)
            close(fds[1])
            guard spawned == 0 else {
                close(fds[0])
                return Result(status: -1, output: String(cString: strerror(spawned)))
            }
            lock.lock(); pid = child; let stopAfterSpawn = cancelled; lock.unlock()
            if stopAfterSpawn { kill() }

            let timer = DispatchWorkItem { [weak self] in self?.kill() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

            // One worker owns the pipe and buffers: no blocked reader survives a closed/reused fd.
            // Keep only the output tail; streaming callbacks still receive every complete line.
            let readFD = fds[0]
            _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
            defer { close(readFD) }
            var collected = Data()
            var pendingLine = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var status: Int32 = 0
            var exitedAt: Date?
            var eof = false
            while true {
                if !eof {
                    var descriptor = pollfd(fd: readFD, events: Int16(POLLIN | POLLHUP), revents: 0)
                    _ = poll(&descriptor, 1, 50)
                    let count = read(readFD, &buffer, buffer.count)
                    if count > 0 {
                        let chunk = Data(buffer[0..<count])
                        collected.append(chunk)
                        if collected.count > 4_194_304 { collected = Data(collected.suffix(4_194_304)) }
                        if let onLine {
                            pendingLine.append(chunk)
                            while let newline = pendingLine.firstIndex(of: 0x0A) {
                                onLine(String(decoding: pendingLine[pendingLine.startIndex..<newline], as: UTF8.self))
                                pendingLine.removeSubrange(pendingLine.startIndex...newline)
                            }
                            if pendingLine.count > 1_048_576 { pendingLine = Data(pendingLine.suffix(1_048_576)) }
                        }
                    } else if count == 0 { eof = true }
                    else if errno != EAGAIN && errno != EINTR { eof = true }
                } else {
                    // A process can close stdout and continue running.
                    usleep(20_000)
                }
                if exitedAt == nil {
                    let waited = waitpid(child, &status, WNOHANG)
                    if waited == child || (waited == -1 && errno != EINTR) { exitedAt = .now }
                }
                if let exitedAt, eof || Date.now.timeIntervalSince(exitedAt) >= 2 { break }
            }
            timer.cancel()
            lock.lock(); finished = true; lock.unlock()
            if let onLine, !pendingLine.isEmpty { onLine(String(decoding: pendingLine, as: UTF8.self)) }
            let output = String(decoding: collected, as: UTF8.self)
            let exit: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
            return Result(status: exit, output: output)
        }
    }
}

/// Semaforo asincrono: al massimo `limit` lavori insieme, gli altri aspettano senza bloccare thread.
actor AsyncGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func enter() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}
