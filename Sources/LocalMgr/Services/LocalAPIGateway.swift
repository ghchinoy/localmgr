import Foundation
import Network
import Combine

@MainActor
class LocalAPIGateway: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var port: UInt16 = 4891
    @Published var requestCount: Int = 0
    @Published var lastLog: String = "Gateway stopped"

    private var listener: NWListener?
    private weak var catalog: ModelCatalogService?
    private weak var runner: BackendRunnerManager?
    private weak var appSettings: AppSettings?
    private weak var telemetry: TelemetryStore?
    private var cancellables = Set<AnyCancellable>()

    private let proxySession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1800.0 // 30 minutes
        config.timeoutIntervalForResource = 3600.0 // 60 minutes
        return URLSession(configuration: config)
    }()

    func configure(catalog: ModelCatalogService, runner: BackendRunnerManager, settings: AppSettings, telemetry: TelemetryStore? = nil) {
        self.catalog = catalog
        self.runner = runner
        self.appSettings = settings
        self.telemetry = telemetry
        self.port = UInt16(settings.gatewayPort)

        settings.$gatewayPort
            .removeDuplicates()
            .sink { [weak self] newPort in
                guard let self = self, UInt16(newPort) != self.port else { return }
                self.port = UInt16(newPort)
                self.lastLog = "Rebinding gateway to port \(newPort)..."
                self.startListening()
            }
            .store(in: &cancellables)

        startListening()
    }

    func startListening() {
        stopListening()
        do {
            let listenerPort = NWEndpoint.Port(rawValue: port)!
            let parameters = NWParameters.tcp
            // (localmgr-b9v.1 / SEC-1): restrict the listener to the loopback
            // interface only. NWListener binds to all interfaces by default
            // absent this, which would expose the unauthenticated local LLM
            // gateway to every other device on the same LAN/WiFi.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: listenerPort)
            let listener = try NWListener(using: parameters, on: listenerPort)
            
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.lastLog = "Listening on http://127.0.0.1:\(self?.port ?? 4891)"
                        AppLog.info("Gateway listening on port \(self?.port ?? 4891)", category: .gateway)
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastLog = "Gateway error: \(error.localizedDescription)"
                        AppLog.error("Gateway listener failed: \(error.localizedDescription)", category: .gateway)
                    case .cancelled:
                        self?.isRunning = false
                        self?.lastLog = "Gateway stopped"
                        AppLog.info("Gateway listener cancelled", category: .gateway)
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            self.isRunning = false
            self.lastLog = "Failed to bind port \(port): \(error.localizedDescription)"
            AppLog.error("Failed to bind gateway to port \(port): \(error.localizedDescription)", category: .gateway)
        }
    }

    func stopListening() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    /// (localmgr-b9v.2 / SEC-2): hard cap on total request size (headers + body).
    /// Requests exceeding this are rejected with 413 rather than silently
    /// truncated/mis-parsed. Explicitly `nonisolated` since it's read from
    /// the nonisolated connection-handling closures below.
    nonisolated private static let maxRequestBytes = 10 * 1024 * 1024 // 10 MB

    nonisolated private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection: connection, buffer: Data())
    }

    /// (localmgr-b9v.2 / SEC-2): accumulates the request across as many TCP
    /// reads as needed instead of assuming it always arrives in a single
    /// <=64KB packet. Parses headers once `\r\n\r\n` is seen, honors
    /// `Content-Length` to know when the body is fully buffered, and
    /// enforces `maxRequestBytes` throughout.
    nonisolated private func receiveRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }

            var newBuffer = buffer
            if let data, !data.isEmpty {
                newBuffer.append(data)
            }

            if newBuffer.count > Self.maxRequestBytes {
                self.sendHTTPResponse(connection: connection, status: 413, body: "{\"error\":\"Request payload exceeds \(Self.maxRequestBytes / 1_048_576)MB limit\"}")
                connection.cancel()
                return
            }

            guard let headerEndRange = newBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil {
                    // Connection closed (or errored) before headers finished; nothing usable to process.
                    connection.cancel()
                    return
                }
                self.receiveRequest(connection: connection, buffer: newBuffer)
                return
            }

            let headerData = newBuffer.subdata(in: newBuffer.startIndex..<headerEndRange.lowerBound)
            let headerLines = (String(data: headerData, encoding: .utf8) ?? "").components(separatedBy: "\r\n")
            let contentLength = self.extractHeaderValue("Content-Length", from: headerLines).flatMap { Int($0) } ?? 0
            let bodyBytesSoFar = newBuffer.distance(from: headerEndRange.upperBound, to: newBuffer.endIndex)

            if bodyBytesSoFar >= contentLength || isComplete {
                Task {
                    await self.incrementRequestCount()
                    await self.processHTTPRequest(data: newBuffer, connection: connection)
                }
                return
            }

            self.receiveRequest(connection: connection, buffer: newBuffer)
        }
    }

    /// Case-insensitive lookup of an HTTP header's value from raw request/response header lines.
    nonisolated private func extractHeaderValue(_ name: String, from lines: [String]) -> String? {
        let prefix = "\(name.lowercased()):"
        for line in lines where line.lowercased().hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// (localmgr-b9v.1 / SEC-1): reflects the request's `Origin` back as
    /// `Access-Control-Allow-Origin` only when it's another process on this
    /// same machine (127.0.0.1 / localhost / ::1, any port) -- e.g. a local
    /// web-based chat UI. A wildcard `*` would let *any* webpage open in the
    /// user's browser (including a malicious one) read responses from this
    /// unauthenticated local LLM gateway.
    nonisolated private func allowedCORSOrigin(from lines: [String]) -> String? {
        guard let origin = extractHeaderValue("Origin", from: lines),
              let url = URL(string: origin),
              let host = url.host else { return nil }
        let normalizedHost = (host.hasPrefix("[") && host.hasSuffix("]")) ? String(host.dropFirst().dropLast()) : host
        let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        return localHosts.contains(normalizedHost) ? origin : nil
    }

    private func incrementRequestCount() {
        self.requestCount += 1
    }

    private func updateLastLog(_ log: String) {
        self.lastLog = log
    }

    nonisolated private func processHTTPRequest(data: Data, connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendHTTPResponse(connection: connection, status: 400, body: "{\"error\":\"Invalid request\"}")
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendHTTPResponse(connection: connection, status: 400, body: "{\"error\":\"Empty request\"}")
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendHTTPResponse(connection: connection, status: 400, body: "{\"error\":\"Malformed HTTP line\"}")
            return
        }

        let method = parts[0]
        let path = parts[1]
        // (localmgr-b9v.1 / SEC-1): only reflect CORS back for same-machine origins.
        let allowedOrigin = allowedCORSOrigin(from: lines)

        await updateLastLog("\(method) \(path)")
        await runner?.recordActivity()

        if method == "GET" && (path == "/v1/models" || path == "/models") {
            await handleModelsList(connection: connection, allowedOrigin: allowedOrigin)
        } else if method == "GET" && (path == "/v1/stats" || path == "/stats" || path == "/health") {
            await handleStats(connection: connection, allowedOrigin: allowedOrigin)
        } else if method == "GET" && path == "/metrics" {
            await handlePrometheusMetrics(connection: connection, allowedOrigin: allowedOrigin)
        } else if method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions") {
            await handleChatCompletions(rawRequest: data, requestString: requestString, connection: connection, allowedOrigin: allowedOrigin)
        } else {
            sendHTTPResponse(connection: connection, status: 404, body: "{\"error\":\"Endpoint not found on LocalMgr Gateway\"}", allowedOrigin: allowedOrigin)
        }
    }

    private func handleModelsList(connection: NWConnection, allowedOrigin: String?) async {
        guard let catalog = catalog, let runner = runner else { return }
        let activeID = runner.activeModel?.id
        let isRunning = runner.status == .running
        let modelsArray = catalog.models.map { model in
            [
                "id": model.name,
                "object": "model",
                "created": Int(Date().timeIntervalSince1970),
                "owned_by": "localmgr",
                "active": isRunning && (model.id == activeID)
            ] as [String : Any]
        }
        let responseDict: [String: Any] = [
            "object": "list",
            "data": modelsArray
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: responseDict),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            sendHTTPResponse(connection: connection, status: 200, body: jsonString, allowedOrigin: allowedOrigin)
        } else {
            sendHTTPResponse(connection: connection, status: 500, body: "{\"error\":\"JSON serialization error\"}", allowedOrigin: allowedOrigin)
        }
    }

    private func handleStats(connection: NWConnection, allowedOrigin: String?) async {
        guard let runner = runner else { return }
        let uptime: Int
        if let start = runner.sessionStartTime, runner.status == .running {
            uptime = Int(Date().timeIntervalSince(start))
        } else {
            uptime = 0
        }

        var activeDict: [String: Any] = ["status": runner.status.rawValue]
        if let active = runner.activeModel {
            activeDict["model"] = active.name
            activeDict["engine"] = active.engineType.rawValue
            activeDict["format"] = active.format.rawValue
            activeDict["port"] = runner.port
            activeDict["uptime_seconds"] = uptime
            activeDict["requests_served"] = runner.totalRequestsServed
            activeDict["total_tokens_processed"] = runner.totalTokensProcessed
            activeDict["last_ttft_ms"] = round(runner.lastTTFTMilliseconds * 100) / 100
            activeDict["last_tps"] = round(runner.lastTokensPerSecond * 100) / 100
        }

        let responseDict: [String: Any] = [
            "status": "ok",
            "gateway_port": runner.port,
            "total_gateway_requests": requestCount,
            "active_runner": activeDict
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: responseDict),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            sendHTTPResponse(connection: connection, status: 200, body: jsonString, allowedOrigin: allowedOrigin)
        } else {
            sendHTTPResponse(connection: connection, status: 500, body: "{\"error\":\"JSON serialization error\"}", allowedOrigin: allowedOrigin)
        }
    }

    private func handlePrometheusMetrics(connection: NWConnection, allowedOrigin: String?) async {
        guard let runner = runner else { return }
        let activeName = runner.activeModel?.name ?? "none"
        let engineName = runner.activeModel?.engineType.rawValue ?? "none"
        let healthVal = runner.status == .running ? "1.0" : "0.0"

        let promText = """
        # HELP ai_gateway_llm_requests_total Total HTTP requests handled by the gateway.
        # TYPE ai_gateway_llm_requests_total counter
        ai_gateway_llm_requests_total{backend="localmgr"} \(requestCount)

        # HELP ai_gateway_llm_upstream_health_status Real-time health status of execution backend.
        # TYPE ai_gateway_llm_upstream_health_status gauge
        ai_gateway_llm_upstream_health_status{backend="localmgr",engine="\(engineName)"} \(healthVal)

        # HELP ai_gateway_llm_token_usage_total Total tokens processed across completions.
        # TYPE ai_gateway_llm_token_usage_total counter
        ai_gateway_llm_token_usage_total{model="\(activeName)",backend="localmgr"} \(runner.totalTokensProcessed)
        """

        sendHTTPResponse(connection: connection, status: 200, body: promText, allowedOrigin: allowedOrigin)
    }

    private func handleChatCompletions(rawRequest: Data, requestString: String, connection: NWConnection, allowedOrigin: String?) async {
        guard let runner = runner, let catalog = catalog else {
            sendHTTPResponse(connection: connection, status: 500, body: "{\"error\":\"Gateway not initialized\"}", allowedOrigin: allowedOrigin)
            return
        }

        var bodyData: Data?
        if let range = rawRequest.range(of: Data("\r\n\r\n".utf8)) {
            bodyData = rawRequest.subdata(in: range.upperBound..<rawRequest.count)
        }

        var requestedModelName: String?
        if let bodyData = bodyData,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            requestedModelName = json["model"] as? String
        }

        if let reqName = requestedModelName, runner.activeModel?.name != reqName {
            if let matched = catalog.models.first(where: { $0.name.localizedCaseInsensitiveContains(reqName) || reqName.localizedCaseInsensitiveContains($0.name) }) {
                if runner.status == .running {
                    AppLog.error("Gateway request for '\(matched.name)' conflicted with active runner '\(runner.activeModel?.name ?? "unknown")' (409)", category: .gateway)
                    sendHTTPResponse(connection: connection, status: 409, body: "{\"error\":\"Conflict: LocalMgr is currently running '\(runner.activeModel?.name ?? "another model")'. Stop current runner before starting '\(matched.name)'.\"}", allowedOrigin: allowedOrigin)
                    return
                }
                updateLastLog("On-demand wake: starting \(matched.name)...")
                runner.startModel(matched)
                
                for _ in 0..<30 {
                    if runner.status == .running { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            } else if runner.status == .running {
                // If model name not found in catalog, but runner is running, fail fast if names conflict unless "default" or "local"
                if reqName.lowercased() != "default" && reqName.lowercased() != "local" {
                    AppLog.error("Gateway request for unknown model '\(reqName)' conflicted with active runner '\(runner.activeModel?.name ?? "unknown")' (409)", category: .gateway)
                    sendHTTPResponse(connection: connection, status: 409, body: "{\"error\":\"Conflict: Requested model '\(reqName)' not found in vault, and runner is active with '\(runner.activeModel?.name ?? "another model")'.\"}", allowedOrigin: allowedOrigin)
                    return
                }
            }
        }

        guard runner.status == .running || runner.activeModel != nil else {
            AppLog.info("Gateway received a completion request with no runner active (503)", category: .gateway)
            sendHTTPResponse(connection: connection, status: 503, body: "{\"error\":\"No local model runner active or ready on port \(runner.port)\"}", allowedOrigin: allowedOrigin)
            return
        }

        let targetURL = URL(string: "http://127.0.0.1:\(runner.port)/v1/chat/completions")!
        var proxyReq = URLRequest(url: targetURL)
        proxyReq.httpMethod = "POST"
        proxyReq.httpBody = bodyData
        proxyReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        proxyReq.timeoutInterval = 1800.0

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let (respData, httpResp) = try await proxySession.data(for: proxyReq)
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let statusCode = (httpResp as? HTTPURLResponse)?.statusCode ?? 200

            var completionTokens = 0
            var promptTokens = 0
            var cachedTokens = 0
            if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
               let usage = json["usage"] as? [String: Any] {
                completionTokens = usage["completion_tokens"] as? Int ?? max(1, respData.count / 4)
                promptTokens = usage["prompt_tokens"] as? Int ?? 0
                if let details = usage["prompt_tokens_details"] as? [String: Any] {
                    cachedTokens = details["cached_tokens"] as? Int ?? 0
                }
            } else {
                completionTokens = max(1, respData.count / 4)
            }

            runner.recordTelemetry(ttftMs: durationMs, durationMs: durationMs, completionTokens: completionTokens)
            if let active = runner.activeModel {
                let thState: String
                switch ProcessInfo.processInfo.thermalState {
                case .nominal: thState = "Nominal"
                case .fair: thState = "Fair"
                case .serious: thState = "Serious"
                case .critical: thState = "Critical"
                @unknown default: thState = "Unknown"
                }
                telemetry?.record(
                    modelName: active.name,
                    engine: active.engineType.rawValue,
                    ttftMs: durationMs * 0.2,
                    durationMs: durationMs,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    cachedTokens: cachedTokens,
                    thermalState: thState
                )
            }

            if let respString = String(data: respData, encoding: .utf8) {
                sendHTTPResponse(connection: connection, status: statusCode, body: respString, allowedOrigin: allowedOrigin)
            } else {
                sendHTTPResponse(connection: connection, status: 502, body: "{\"error\":\"Invalid response encoding from backend\"}", allowedOrigin: allowedOrigin)
            }
        } catch {
            AppLog.error("Proxy request to local engine failed: \(error.localizedDescription)", category: .gateway)
            sendHTTPResponse(connection: connection, status: 502, body: "{\"error\":\"Proxy error: \(error.localizedDescription)\"}", allowedOrigin: allowedOrigin)
        }
    }

    /// (localmgr-b9v.1 / SEC-1): `allowedOrigin` is only ever a non-nil value
    /// when `allowedCORSOrigin(from:)` validated the request's `Origin` as a
    /// same-machine origin; passing `nil` (the default) omits the CORS
    /// header entirely rather than the previous unconditional wildcard `*`.
    nonisolated private func sendHTTPResponse(connection: NWConnection, status: Int, body: String, allowedOrigin: String? = nil) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
        default: statusText = "Error"
        }

        var headerLines = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: application/json",
            "Content-Length: \(body.utf8.count)",
            "Connection: close"
        ]
        if let allowedOrigin {
            headerLines.append("Access-Control-Allow-Origin: \(allowedOrigin)")
            headerLines.append("Vary: Origin")
        }
        let response = headerLines.joined(separator: "\r\n") + "\r\n\r\n" + body

        let data = Data(response.utf8)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
