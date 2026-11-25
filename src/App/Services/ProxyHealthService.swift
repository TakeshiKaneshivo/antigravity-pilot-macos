import Darwin
import Foundation

enum ProxyHealthService {
    static func probe(config: ProxyConfig, includeInternetCheck: Bool = true) async -> ProxyHealthReport {
        let host = config.normalizedHost
        let hookPort = config.hookPort
        let envPort = config.envPort
        let language = config.appLanguage

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let report = probeSync(
                    host: host,
                    hookPort: hookPort,
                    envPort: envPort,
                    includeInternetCheck: includeInternetCheck,
                    language: language
                )
                continuation.resume(returning: report)
            }
        }
    }

    static func probeSync(
        host rawHost: String,
        hookPort: Int,
        envPort: Int,
        includeInternetCheck: Bool = true,
        targetHost: String = "www.google.com",
        targetPort: UInt16 = 80,
        language: AppLanguage = L10n.current
    ) -> ProxyHealthReport {
        let now = Date()
        let host = ProxyConfig.normalizeHost(rawHost)
        guard ProxyConfig.isValidNumericIP(host), (1...65535).contains(hookPort), (1...65535).contains(envPort) else {
            return ProxyHealthReport(
                tcpReachable: false,
                socks5HandshakeOK: false,
                envPortReachable: false,
                internetReachable: nil,
                latencyMs: nil,
                level: .failed,
                summaryTitle: L10n.t("配置无效", "Invalid Config", language),
                detailMessage: L10n.t(
                    "请检查代理 IP（如 127.0.0.1）与端口范围（1-65535）。",
                    "Check numeric proxy IP (e.g. 127.0.0.1) and port range (1-65535).",
                    language
                ),
                checkedAt: now
            )
        }

        let envReachable = (envPort == hookPort)
            ? nil
            : testTCPConnect(host: host, port: envPort, timeoutMs: 1200)

        let startNs = DispatchTime.now().uptimeNanoseconds
        guard let fd = connectSocket(host: host, port: hookPort, timeoutMs: 1500) else {
            return ProxyHealthReport(
                tcpReachable: false,
                socks5HandshakeOK: false,
                envPortReachable: envReachable ?? false,
                internetReachable: nil,
                latencyMs: nil,
                level: .failed,
                summaryTitle: L10n.t("端口未连通", "Unreachable", language),
                detailMessage: L10n.t(
                    zhHans: "无法连接 \(host):\(hookPort)，请确认 Clash / 代理软件已启动。",
                    zhHant: "無法連線 \(host):\(hookPort)，請確認 Clash / 代理軟體已啟動。",
                    en: "Cannot connect to \(host):\(hookPort). Ensure your proxy client is running.",
                    ru: "Не удалось подключиться к \(host):\(hookPort). Убедитесь, что прокси-клиент запущен.",
                    language
                ),
                checkedAt: now
            )
        }
        defer { close(fd) }

        setSocketTimeouts(fd: fd, timeoutMs: 2500)

        // Stage 2: SOCKS5 greeting (VER=5, NMETHODS=1, METHOD=0 no-auth)
        let greeting: [UInt8] = [0x05, 0x01, 0x00]
        guard sendAll(fd: fd, bytes: greeting) else {
            return ProxyHealthReport(
                tcpReachable: true,
                socks5HandshakeOK: false,
                envPortReachable: envReachable ?? true,
                internetReachable: nil,
                latencyMs: nil,
                level: .degraded,
                summaryTitle: L10n.t("握手超时", "Handshake Timeout", language),
                detailMessage: L10n.t(
                    zhHans: "\(host):\(hookPort) TCP 已连接，但 SOCKS5 握手发送失败。",
                    zhHant: "\(host):\(hookPort) TCP 已連線，但 SOCKS5 交握發送失敗。",
                    en: "TCP connected to \(host):\(hookPort), but failed to send SOCKS5 greeting.",
                    ru: "TCP к \(host):\(hookPort) установлен, но не удалось отправить приветствие SOCKS5.",
                    language
                ),
                checkedAt: now
            )
        }

        guard let helloReply = recvExact(fd: fd, count: 2) else {
            return ProxyHealthReport(
                tcpReachable: true,
                socks5HandshakeOK: false,
                envPortReachable: envReachable ?? true,
                internetReachable: nil,
                latencyMs: nil,
                level: .degraded,
                summaryTitle: L10n.t("非 SOCKS5 端口", "Not SOCKS5", language),
                detailMessage: L10n.t(
                    zhHans: "\(host):\(hookPort) TCP 可连接，但未返回有效的 SOCKS5 响应（请勿填入纯 HTTP 端口）。",
                    zhHant: "\(host):\(hookPort) TCP 可連線，但未傳回有效的 SOCKS5 回應（請勿填入純 HTTP 連接埠）。",
                    en: "\(host):\(hookPort) accepted TCP but did not return a valid SOCKS5 greeting (avoid HTTP-only ports).",
                    ru: "\(host):\(hookPort) принял TCP, но не вернул ответ SOCKS5 (не используйте порт только для HTTP).",
                    language
                ),
                checkedAt: now
            )
        }

        if helloReply[0] != 0x05 {
            let looksHttp = (helloReply[0] == 0x48 && helloReply[1] == 0x54) // "HT"
            return ProxyHealthReport(
                tcpReachable: true,
                socks5HandshakeOK: false,
                envPortReachable: envReachable ?? true,
                internetReachable: nil,
                latencyMs: nil,
                level: .degraded,
                summaryTitle: L10n.t("非 SOCKS5 端口", "Not SOCKS5", language),
                detailMessage: looksHttp
                    ? L10n.t(
                        zhHans: "\(host):\(hookPort) 返回了 HTTP 响应，不是 SOCKS5 / 混合端口。",
                        zhHant: "\(host):\(hookPort) 傳回了 HTTP 回應，不是 SOCKS5 / 混合連接埠。",
                        en: "\(host):\(hookPort) returned an HTTP response instead of SOCKS5 / mixed.",
                        ru: "\(host):\(hookPort) вернул HTTP-ответ вместо SOCKS5 / смешанного порта.",
                        language
                    )
                    : L10n.t(
                        zhHans: "\(host):\(hookPort) 协议版本响应异常（0x\(String(helloReply[0], radix: 16))）。",
                        zhHant: "\(host):\(hookPort) 協定版本回應異常（0x\(String(helloReply[0], radix: 16))）。",
                        en: "\(host):\(hookPort) returned unexpected protocol version (0x\(String(helloReply[0], radix: 16))).",
                        ru: "\(host):\(hookPort) вернул неожиданную версию протокола (0x\(String(helloReply[0], radix: 16))).",
                        language
                    ),
                checkedAt: now
            )
        }

        if helloReply[1] != 0x00 {
            return ProxyHealthReport(
                tcpReachable: true,
                socks5HandshakeOK: false,
                envPortReachable: envReachable ?? true,
                internetReachable: nil,
                latencyMs: nil,
                level: .degraded,
                summaryTitle: L10n.t("需要认证", "Auth Required", language),
                detailMessage: L10n.t(
                    zhHans: "代理端口 \(host):\(hookPort) 拒绝无认证 SOCKS5（method=0x\(String(helloReply[1], radix: 16))）。",
                    zhHant: "代理連接埠 \(host):\(hookPort) 拒絕無驗證 SOCKS5（method=0x\(String(helloReply[1], radix: 16))）。",
                    en: "Proxy port \(host):\(hookPort) rejected no-auth SOCKS5 (method=0x\(String(helloReply[1], radix: 16))).",
                    ru: "Порт \(host):\(hookPort) отклонил SOCKS5 без авторизации (method=0x\(String(helloReply[1], radix: 16))).",
                    language
                ),
                checkedAt: now
            )
        }

        let effectiveEnvReachable = envReachable ?? true

        if !includeInternetCheck {
            let ms = Int((DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000)
            return ProxyHealthReport(
                tcpReachable: true,
                socks5HandshakeOK: true,
                envPortReachable: effectiveEnvReachable,
                internetReachable: nil,
                latencyMs: ms,
                level: effectiveEnvReachable ? .healthy : .degraded,
                summaryTitle: effectiveEnvReachable
                    ? L10n.t("SOCKS5 就绪", "SOCKS5 Ready", language)
                    : L10n.t("ENV 端口异常", "ENV Port Error", language),
                detailMessage: effectiveEnvReachable
                    ? L10n.t(
                        zhHans: "TCP 与 SOCKS5 协议握手正常（\(ms) ms）。",
                        zhHant: "TCP 與 SOCKS5 協定交握正常（\(ms) ms）。",
                        en: "TCP and SOCKS5 handshake succeeded (\(ms) ms).",
                        ru: "TCP и рукопожатие SOCKS5 успешны (\(ms) ms).",
                        language
                    )
                    : L10n.t(
                        zhHans: "SOCKS5 端口 \(hookPort) 正常，但环境变量端口 \(envPort) 不可达。",
                        zhHant: "SOCKS5 連接埠 \(hookPort) 正常，但環境變數連接埠 \(envPort) 無法連線。",
                        en: "SOCKS5 port \(hookPort) is OK, but ENV port \(envPort) is unreachable.",
                        ru: "Порт SOCKS5 \(hookPort) работает, но порт ENV \(envPort) недоступен.",
                        language
                    ),
                checkedAt: now
            )
        }

        // Stage 3: SOCKS5 CONNECT targetHost:targetPort + HTTP /generate_204
        let hostBytes = Array(targetHost.utf8)
        guard hostBytes.count > 0, hostBytes.count <= 255 else {
            return ProxyHealthReport(
                tcpReachable: true,
                socks5HandshakeOK: true,
                envPortReachable: effectiveEnvReachable,
                internetReachable: false,
                latencyMs: nil,
                level: .degraded,
                summaryTitle: L10n.t("SOCKS5 就绪", "SOCKS5 Ready", language),
                detailMessage: L10n.t("SOCKS5 握手正常，目标探测域名无效。", "SOCKS5 handshake OK, invalid probe target host.", language),
                checkedAt: now
            )
        }

        var connectReq: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)]
        connectReq.append(contentsOf: hostBytes)
        connectReq.append(UInt8((targetPort >> 8) & 0xFF))
        connectReq.append(UInt8(targetPort & 0xFF))

        guard sendAll(fd: fd, bytes: connectReq),
              let repHeader = recvExact(fd: fd, count: 4),
              repHeader[0] == 0x05,
              repHeader[1] == 0x00,
              consumeSocks5ReplyTail(fd: fd, atyp: repHeader[3]) else {
            return ProxyHealthReport(
                tcpReachable: true,
                socks5HandshakeOK: true,
                envPortReachable: effectiveEnvReachable,
                internetReachable: false,
                latencyMs: nil,
                level: .degraded,
                summaryTitle: L10n.t("外网未通", "No Internet", language),
                detailMessage: L10n.t(
                    zhHans: "SOCKS5 握手成功，但通过代理连接 \(targetHost):\(targetPort) 失败，请检查代理节点状态。",
                    zhHant: "SOCKS5 交握成功，但透過代理連線 \(targetHost):\(targetPort) 失敗，請檢查代理節點狀態。",
                    en: "SOCKS5 handshake OK, but failed to reach \(targetHost):\(targetPort) via proxy. Check your proxy node.",
                    ru: "SOCKS5 успешен, но не удалось подключиться к \(targetHost):\(targetPort) через прокси. Проверьте узел.",
                    language
                ),
                checkedAt: now
            )
        }

        let httpReq = "GET /generate_204 HTTP/1.1\r\nHost: \(targetHost)\r\nConnection: close\r\n\r\n"
        guard sendAll(fd: fd, bytes: Array(httpReq.utf8)),
              let statusLine = recvHttpStatusLine(fd: fd, maxBytes: 512),
              let statusCode = parseHttpStatusCode(statusLine),
              (200..<400).contains(statusCode) else {
            return ProxyHealthReport(
                tcpReachable: true,
                socks5HandshakeOK: true,
                envPortReachable: effectiveEnvReachable,
                internetReachable: false,
                latencyMs: nil,
                level: .degraded,
                summaryTitle: L10n.t("外网未通", "No Internet", language),
                detailMessage: L10n.t(
                    zhHans: "SOCKS5 隧道已建立，但访问 \(targetHost)/generate_204 无有效响应，请检查代理节点。",
                    zhHant: "SOCKS5 通道已建立，但存取 \(targetHost)/generate_204 無有效回應，請檢查代理節點。",
                    en: "SOCKS5 tunnel established, but \(targetHost)/generate_204 returned no valid response.",
                    ru: "Туннель SOCKS5 установлен, но \(targetHost)/generate_204 не ответил корректно.",
                    language
                ),
                checkedAt: now
            )
        }

        let latencyMs = max(1, Int((DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000))
        if !effectiveEnvReachable {
            return ProxyHealthReport(
                tcpReachable: true,
                socks5HandshakeOK: true,
                envPortReachable: false,
                internetReachable: true,
                latencyMs: latencyMs,
                level: .degraded,
                summaryTitle: L10n.t("ENV 端口异常", "ENV Port Error", language),
                detailMessage: L10n.t(
                    zhHans: "SOCKS5 外网已通（\(latencyMs) ms），但环境变量端口 \(host):\(envPort) 无法连接，Go 子进程可能超时。",
                    zhHant: "SOCKS5 外網已通（\(latencyMs) ms），但環境變數連接埠 \(host):\(envPort) 無法連線，Go 子程序可能逾時。",
                    en: "SOCKS5 internet OK (\(latencyMs) ms), but ENV port \(host):\(envPort) is unreachable; Go helpers may time out.",
                    ru: "Выход через SOCKS5 работает (\(latencyMs) ms), но порт ENV \(host):\(envPort) недоступен.",
                    language
                ),
                checkedAt: now
            )
        }

        return ProxyHealthReport(
            tcpReachable: true,
            socks5HandshakeOK: true,
            envPortReachable: true,
            internetReachable: true,
            latencyMs: latencyMs,
            level: .healthy,
            summaryTitle: L10n.t(
                zhHans: "已连通 · \(latencyMs) ms",
                zhHant: "已連通 · \(latencyMs) ms",
                en: "Connected · \(latencyMs) ms",
                ru: "Подключено · \(latencyMs) ms",
                language
            ),
            detailMessage: L10n.t(
                zhHans: "TCP 端口可达 · SOCKS5 握手正常 · 外网探测通过（\(latencyMs) ms）。",
                zhHant: "TCP 連接埠可達 · SOCKS5 交握正常 · 外網探測通過（\(latencyMs) ms）。",
                en: "TCP reachable · SOCKS5 handshake OK · Internet check passed (\(latencyMs) ms).",
                ru: "TCP доступен · SOCKS5 успешен · Выход в сеть работает (\(latencyMs) ms).",
                language
            ),
            checkedAt: now
        )
    }

    static func testTCPConnect(host: String, port: Int, timeoutMs: Int) -> Bool {
        guard let fd = connectSocket(host: host, port: port, timeoutMs: timeoutMs) else {
            return false
        }
        close(fd)
        return true
    }

    private static func connectSocket(host: String, port: Int, timeoutMs: Int) -> Int32? {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &result) == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                let oldFlags = fcntl(fd, F_GETFL, 0)
                if oldFlags >= 0 {
                    _ = fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK)
                }
                let rc = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
                var connected = (rc == 0)
                if rc != 0 && errno == EINPROGRESS {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&pfd, 1, Int32(timeoutMs))
                    if ready > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
                        var soErr: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0 && soErr == 0 {
                            connected = true
                        }
                    }
                }
                if connected {
                    if oldFlags >= 0 {
                        _ = fcntl(fd, F_SETFL, oldFlags)
                    }
                    return fd
                }
                close(fd)
            }
            current = info.pointee.ai_next
        }
        return nil
    }

    private static func setSocketTimeouts(fd: Int32, timeoutMs: Int) {
        var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: __darwin_suseconds_t((timeoutMs % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func sendAll(fd: Int32, bytes: [UInt8]) -> Bool {
        var sent = 0
        return bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            while sent < bytes.count {
                let n = Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                sent += n
            }
            return true
        }
    }

    private static func recvExact(fd: Int32, count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.recv(fd, raw.baseAddress!.advanced(by: got), count - got, 0)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { return nil }
            got += n
        }
        return buffer
    }

    private static func consumeSocks5ReplyTail(fd: Int32, atyp: UInt8) -> Bool {
        switch atyp {
        case 0x01:
            return recvExact(fd: fd, count: 6) != nil
        case 0x04:
            return recvExact(fd: fd, count: 18) != nil
        case 0x03:
            guard let lenBuf = recvExact(fd: fd, count: 1) else { return false }
            return recvExact(fd: fd, count: Int(lenBuf[0]) + 2) != nil
        default:
            return false
        }
    }

    private static func recvHttpStatusLine(fd: Int32, maxBytes: Int) -> String? {
        var collected = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256)
        while collected.count < maxBytes {
            let n = chunk.withUnsafeMutableBytes { raw in
                Darwin.recv(fd, raw.baseAddress!, min(256, maxBytes - collected.count), 0)
            }
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            collected.append(contentsOf: chunk[0..<n])
            if let str = String(bytes: collected, encoding: .utf8),
               let lineEnd = str.range(of: "\r\n") ?? str.range(of: "\n") {
                return String(str[..<lineEnd.lowerBound])
            }
        }
        return String(bytes: collected, encoding: .utf8)
    }

    private static func parseHttpStatusCode(_ statusLine: String) -> Int? {
        let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else { return nil }
        return Int(parts[1])
    }
}
