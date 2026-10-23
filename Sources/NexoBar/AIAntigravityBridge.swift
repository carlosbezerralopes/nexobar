import Foundation
import Darwin
import Security

// AntigravityBridge/LocalhostTrust behavior adapted from Codenotch (MIT).
// Discovery is native and read-only; this bridge never starts a language server.
enum AIAntigravityBridge {
    static let service = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    static let csrfHeader = "x-codeium-csrf-token"
    struct Identity: Equatable {
        var pid: Int32
        var startedAt: Date
        var executable: String
    }
    struct Listener: Hashable {
        var host: String
        var port: Int
        var generation: UInt64
    }
    struct Candidate {
        var identity: Identity
        var arguments: [String]
        var listeners: [Listener]
    }
    struct Endpoint: CustomStringConvertible, CustomDebugStringConvertible {
        let identity: Identity
        let listeners: [Listener]
        fileprivate let csrfToken: String
        var description: String { "Antigravity loopback endpoint (CSRF oculto)" }
        var debugDescription: String { description }
    }
    typealias Request = (Endpoint, Listener, TimeInterval) throws -> Data

    static func read(now: Date) throws -> IndicatorReading {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        guard let endpoint = discover(deadline: deadline) else { throw AIReadError.unavailable }
        return try quota(from: endpoint, now: now, deadline: deadline)
    }
    static func quota(from endpoint: Endpoint, now: Date, deadline: TimeInterval? = nil, request: Request? = nil) throws -> IndicatorReading {
        let deadline = deadline ?? ProcessInfo.processInfo.systemUptime + 20
        let request = request ?? { endpoint, listener, timeout in try AILocalQuotaRequest.read(endpoint: endpoint, listener: listener, timeout: timeout) }
        var lastError: Error = AIReadError.unavailable
        for listener in endpoint.listeners {
            let remaining = min(8, deadline - ProcessInfo.processInfo.systemUptime)
            guard remaining > 0 else { throw AIReadError.timedOut }
            do {
                // Validation also applies to injected transports and constructed endpoints.
                _ = try makeRequest(endpoint: endpoint, listener: listener, timeout: remaining)
                let bytes = try request(endpoint, listener, remaining)
                guard bytes.count <= 1024 * 1024 else { throw AIReadError.excessiveOutput }
                let windows = AntigravityQuotaParser.parse(bytes, now: now)
                guard !windows.isEmpty else { throw AIReadError.malformed }
                let gemini = windows.filter { $0.id.hasPrefix("gemini") || ($0.group?.lowercased().contains("gemini") ?? false) }
                let candidates = (gemini.isEmpty ? windows : gemini).filter { $0.usedFraction != nil }
                let usable = candidates.filter { ($0.usedFraction ?? 1) < 1 }
                let headline = (usable.isEmpty ? candidates : usable).max { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) }?.id ?? "gemini-hourly"
                return try AIProviderIntegrations.converted(.antigravity, windows, headline: headline, now: now,
                                                           source: "Antigravity IDE · cotas do language server local")
            } catch { lastError = error }
        }
        throw lastError
    }

    static func discover(deadline: TimeInterval) -> Endpoint? {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: min(8192, Int(count) / MemoryLayout<pid_t>.stride + 32))
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return nil }
        for pid in pids.prefix(min(pids.count, Int(bytes) / MemoryLayout<pid_t>.stride)).reversed() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            guard let identity = processIdentity(pid), trustedServer(identity.executable),
                  let arguments = processArguments(pid) else { continue }
            let sockets = listeningSockets(of: pid)
            guard processIdentity(pid) == identity else { continue }
            if let endpoint = discover(candidates: [Candidate(identity: identity, arguments: arguments, listeners: sockets)]) { return endpoint }
        }
        return nil
    }
    static func discover(candidates: [Candidate]) -> Endpoint? {
        for candidate in candidates {
            guard candidate.identity.pid > 0, trustedServer(candidate.identity.executable),
                  let token = csrfToken(arguments: candidate.arguments) else { continue }
            let sockets = Set(candidate.listeners.filter { isLoopback($0.host) && (1...65535).contains($0.port) })
                .sorted { $0.port == $1.port ? $0.host < $1.host : $0.port < $1.port }
            guard !sockets.isEmpty else { continue }
            return Endpoint(identity: candidate.identity, listeners: Array(sockets.prefix(4)), csrfToken: token)
        }
        return nil
    }
    static func trustedServer(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"), URL(fileURLWithPath: path).standardizedFileURL.path == path,
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("language_server"),
              let marker = path.range(of: "/Contents/") else { return false }
        let app = URL(fileURLWithPath: String(path[..<marker.lowerBound]))
        guard app.pathExtension == "app", let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.google.antigravity" else { return false }
        return path.hasPrefix(app.path + "/Contents/")
    }
    static func csrfToken(arguments: [String]) -> String? {
        var values: [String] = []
        for index in arguments.indices.dropFirst() {
            if arguments[index] == "--csrf_token", arguments.indices.contains(index + 1) { values.append(arguments[index + 1]) }
            if arguments[index].hasPrefix("--csrf_token=") { values.append(String(arguments[index].dropFirst("--csrf_token=".count))) }
        }
        guard values.count == 1, let token = values.first, !token.isEmpty, token.utf8.count <= 4096,
              !token.hasPrefix("--"), token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { return nil }
        return token
    }

    static func processIdentity(_ pid: Int32) -> Identity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return Identity(pid: pid, startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000),
                        executable: String(cString: path))
    }
    static func processArguments(_ pid: Int32) -> [String]? {
        var maxArgs: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var limitMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&limitMIB, 2, &maxArgs, &size, nil, 0) == 0, maxArgs > 0, maxArgs <= 2 * 1024 * 1024 else { return nil }
        var bytes = Data(count: Int(maxArgs))
        var count = bytes.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &count, nil, 0) }
        guard result == 0, count >= 4, count <= bytes.count else { return nil }
        bytes.count = count
        return parseArguments(bytes)
    }
    static func parseArguments(_ bytes: Data) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard (1...1024).contains(argc) else { return nil }
        let data = [UInt8](bytes)
        var offset = 4
        func next() -> String? {
            guard offset < data.count, let end = data[offset...].firstIndex(of: 0), end - offset <= 65536,
                  let text = String(bytes: data[offset..<end], encoding: .utf8) else { return nil }
            offset = end + 1
            return text
        }
        guard next() != nil else { return nil } // exec path, then padding before argv[0]
        while offset < data.count, data[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argc { guard let value = next() else { return nil }; arguments.append(value) }
        // Stop at argc: environment variables are neither decoded nor considered flags.
        return arguments
    }

    static func listeningSockets(of pid: Int32) -> [Listener] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: min(8192, Int(needed) / MemoryLayout<proc_fdinfo>.stride + 8))
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard bytes > 0 else { return [] }
        var result: [Listener] = []
        for fd in fds.prefix(min(fds.count, Int(bytes) / MemoryLayout<proc_fdinfo>.stride)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == Int32(SOCKINFO_TCP), socket.psi.soi_protocol == IPPROTO_TCP,
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let address = socket.psi.soi_proto.pri_tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: address.insi_lport)))
            guard (1...65535).contains(port) else { continue }
            if address.insi_vflag & UInt8(INI_IPV4) != 0 {
                var ipv4 = address.insi_laddr.ina_46.i46a_addr4
                let value = UInt32(bigEndian: ipv4.s_addr)
                if value == 0 { result.append(Listener(host: "127.0.0.1", port: port, generation: address.insi_gencnt)) }
                else if value >> 24 == 127 {
                    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &ipv4, &text, socklen_t(text.count)) != nil { result.append(Listener(host: String(cString: text), port: port, generation: address.insi_gencnt)) }
                }
            }
            if address.insi_vflag & UInt8(INI_IPV6) != 0 {
                var ipv6 = address.insi_laddr.ina_6
                let bytes = withUnsafeBytes(of: &ipv6) { Array($0.prefix(16)) }
                if bytes.allSatisfy({ $0 == 0 }) || (bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes.last == 1) {
                    result.append(Listener(host: "::1", port: port, generation: address.insi_gencnt))
                }
            }
        }
        return Array(Set(result))
    }
    static func stillOwns(_ endpoint: Endpoint, listener: Listener) -> Bool {
        processIdentity(endpoint.identity.pid) == endpoint.identity && trustedServer(endpoint.identity.executable)
            && listeningSockets(of: endpoint.identity.pid).contains(listener)
    }
    static func isLoopback(_ host: String) -> Bool {
        if host == "::1" { return true }
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1 && UInt32(bigEndian: address.s_addr) >> 24 == 127
    }
    static func allowedURL(_ url: URL, listener: Listener) -> Bool {
        let host = (url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return url.scheme == "https" && isLoopback(host) && host == listener.host && url.port == listener.port
            && url.path == service && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }
    static func allowsTrust(host: String, port: Int, method: String, listener: Listener, ownsSocket: Bool) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ownsSocket && isLoopback(host) && host == listener.host && port == listener.port
            && method == NSURLAuthenticationMethodServerTrust
    }
    static func makeRequest(endpoint: Endpoint, listener: Listener, timeout: TimeInterval) throws -> URLRequest {
        guard endpoint.listeners.contains(listener), isLoopback(listener.host), (1...65535).contains(listener.port) else { throw AIReadError.unavailable }
        var components = URLComponents(); components.scheme = "https"; components.host = listener.host == "::1" ? "[::1]" : listener.host
        components.port = listener.port; components.path = service
        guard let url = components.url, allowedURL(url, listener: listener) else { throw AIReadError.unavailable }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = max(0.1, timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(endpoint.csrfToken, forHTTPHeaderField: csrfHeader)
        request.httpBody = Data(#"{"forceRefresh":true}"#.utf8)
        return request
    }
}

// This session cannot access remote hosts, redirects, proxy credentials or caches.
final class AILocalQuotaRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let endpoint: AIAntigravityBridge.Endpoint
    private let listener: AIAntigravityBridge.Listener
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var failure: Error?
    private let done = DispatchSemaphore(value: 0)
    init(endpoint: AIAntigravityBridge.Endpoint, listener: AIAntigravityBridge.Listener) { self.endpoint = endpoint; self.listener = listener }
    static func read(endpoint: AIAntigravityBridge.Endpoint, listener: AIAntigravityBridge.Listener, timeout: TimeInterval) throws -> Data {
        guard AIAntigravityBridge.stillOwns(endpoint, listener: listener) else { throw AIReadError.unavailable }
        let request = try AIAntigravityBridge.makeRequest(endpoint: endpoint, listener: listener, timeout: timeout)
        let receiver = AILocalQuotaRequest(endpoint: endpoint, listener: listener)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        let task = session.dataTask(with: request); task.resume()
        guard receiver.done.wait(timeout: .now() + timeout) == .success else { task.cancel(); session.invalidateAndCancel(); throw AIReadError.timedOut }
        session.finishTasksAndInvalidate()
        if let failure = receiver.failure { throw failure }
        switch receiver.response?.statusCode ?? 0 {
        case 200: return receiver.bytes
        case 401, 403: throw AIReadError.authentication
        case 429: throw AIReadError.rateLimited
        default: throw AIReadError.unavailable
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let url = response.url, AIAntigravityBridge.allowedURL(url, listener: listener) else { failure = AIReadError.unavailable; completionHandler(.cancel); return }
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > 1024 * 1024 { failure = AIReadError.excessiveOutput; completionHandler(.cancel) }
        else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= 1024 * 1024 else { failure = AIReadError.excessiveOutput; dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { failure = failure ?? error; done.signal() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard AIAntigravityBridge.allowsTrust(host: host, port: challenge.protectionSpace.port,
                                             method: challenge.protectionSpace.authenticationMethod, listener: listener,
                                             ownsSocket: AIAntigravityBridge.stillOwns(endpoint, listener: listener)),
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
