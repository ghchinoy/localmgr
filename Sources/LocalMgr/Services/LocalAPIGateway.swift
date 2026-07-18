import Foundation
import Network
import Combine

@MainActor
class LocalAPIGateway: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var port: UInt16 = 4891
    @Published var requestCount: Int = 0
    @Published var lastLog: String = "Gateway stopped"

    /// Most recent gateway-side failure (bind failure, 409 model conflict,
    /// upstream unreachable/timeout, malformed request), typed as
    /// `LocalMgrError` so the exact same structured error is both what gets
    /// logged via `AppLog` and what's serialized into the HTTP error
    /// response body -- a developer's curl/IDE output and the in-app
    /// Diagnostics view can never disagree about what happened.
    @Published var lastError: LocalMgrError?

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
            let parameters = NWParameters.tcp
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
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
                        self?.recordGatewayError(LocalMgrError(
                            message: "The gateway listener failed while running.",
                            kind: "gateway-listener-failed",
                            detail: error.localizedDescription,
                            fix: "The gateway will need to be restarted (toggle it or restart LocalMgr)."
                        ))
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
            recordGatewayError(LocalMgrError(
                message: "Failed to bind the gateway to port \(port).",
                kind: "gateway-bind-failed",
                detail: error.localizedDescription,
                fix: "Check whether another process is already using port \(port), or choose a different gateway port in Settings."
            ))
        }
    }

    /// Records a gateway-side failure as a `LocalMgrError`, both for
    /// `lastError` (UI banner) and `AppLog` (unified logging + Diagnostics
    /// view), so the two surfaces can never disagree about what happened.
    /// Callers from `nonisolated` connection-handling contexts should
    /// `await` this via `Task { @MainActor in ... }` or by calling it from
    /// an already-`await`ed MainActor hop (see `sendErrorResponse`).
    private func recordGatewayError(_ error: LocalMgrError) {
        self.lastError = error
        AppLog.error(error.logSummary, category: .gateway)
    }

    func stopListening() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    nonisolated private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }

            Task {
                await self.incrementRequestCount()
                await self.processHTTPRequest(data: data, connection: connection)
            }
        }
    }

    private func incrementRequestCount() {
        self.requestCount += 1
    }

    private func updateLastLog(_ log: String) {
        self.lastLog = log
    }

    nonisolated private func processHTTPRequest(data: Data, connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            await sendErrorResponse(connection: connection, status: 400, error: LocalMgrError(
                message: "Malformed request: body was not valid UTF-8.",
                kind: "gateway-malformed-request"
            ))
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            await sendErrorResponse(connection: connection, status: 400, error: LocalMgrError(
                message: "Malformed request: empty request.",
                kind: "gateway-malformed-request"
            ))
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            await sendErrorResponse(connection: connection, status: 400, error: LocalMgrError(
                message: "Malformed request: could not parse the HTTP request line.",
                kind: "gateway-malformed-request",
                detail: firstLine
            ))
            return
        }

        let method = parts[0]
        let path = parts[1]

        await updateLastLog("\(method) \(path)")
        await runner?.recordActivity()

        if method == "GET" && (path == "/v1/models" || path == "/models") {
            await handleModelsList(connection: connection)
        } else if method == "GET" && (path == "/v1/stats" || path == "/stats" || path == "/health") {
            await handleStats(connection: connection)
        } else if method == "GET" && path == "/metrics" {
            await handlePrometheusMetrics(connection: connection)
        } else if method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions") {
            await handleChatCompletions(rawRequest: data, requestString: requestString, connection: connection)
        } else {
            sendHTTPResponse(connection: connection, status: 404, body: "{\"error\":\"Endpoint not found on LocalMgr Gateway\"}")
        }
    }

    private func handleModelsList(connection: NWConnection) async {
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
            sendHTTPResponse(connection: connection, status: 200, body: jsonString)
        } else {
            sendHTTPResponse(connection: connection, status: 500, body: "{\"error\":\"JSON serialization error\"}")
        }
    }

    private func handleStats(connection: NWConnection) async {
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
            sendHTTPResponse(connection: connection, status: 200, body: jsonString)
        } else {
            sendHTTPResponse(connection: connection, status: 500, body: "{\"error\":\"JSON serialization error\"}")
        }
    }

    private func handlePrometheusMetrics(connection: NWConnection) async {
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

        sendHTTPResponse(connection: connection, status: 200, body: promText)
    }

    private func handleChatCompletions(rawRequest: Data, requestString: String, connection: NWConnection) async {
        guard let runner = runner, let catalog = catalog else {
            sendErrorResponse(connection: connection, status: 500, error: LocalMgrError(
                message: "Gateway is not fully initialized yet.",
                kind: "gateway-not-initialized"
            ))
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
                    let activeName = runner.activeModel?.name ?? "another model"
                    sendErrorResponse(connection: connection, status: 409, error: LocalMgrError(
                        message: "Conflict: LocalMgr is currently running '\(activeName)'.",
                        kind: "gateway-model-conflict",
                        fix: "Stop the current runner before starting '\(matched.name)', or point this request at '\(activeName)' instead."
                    ))
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
                    let activeName = runner.activeModel?.name ?? "another model"
                    sendErrorResponse(connection: connection, status: 409, error: LocalMgrError(
                        message: "Conflict: requested model '\(reqName)' was not found in the vault, and the runner is active with '\(activeName)'.",
                        kind: "gateway-model-conflict",
                        fix: "Attach a folder containing '\(reqName)', or request \"default\"/\"local\" to use the currently running model."
                    ))
                    return
                }
            }
        }

        guard runner.status == .running || runner.activeModel != nil else {
            sendErrorResponse(connection: connection, status: 503, error: LocalMgrError(
                message: "No local model runner is active or ready.",
                kind: "gateway-no-runner",
                detail: "Gateway port: \(runner.port)",
                fix: "Start a model runner from LocalMgr, or specify a \"model\" in the request so the gateway can wake one on demand."
            ))
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
                sendHTTPResponse(connection: connection, status: statusCode, body: respString)
            } else {
                sendErrorResponse(connection: connection, status: 502, error: LocalMgrError(
                    message: "Received an invalid (non-UTF8) response from the local engine.",
                    kind: "gateway-invalid-upstream-encoding"
                ))
            }
        } catch {
            let isTimeout = (error as NSError).code == NSURLErrorTimedOut
            sendErrorResponse(connection: connection, status: 502, error: LocalMgrError(
                message: isTimeout
                    ? "The request to the local engine timed out."
                    : "Couldn't reach the local engine.",
                kind: isTimeout ? "gateway-upstream-timeout" : "gateway-upstream-unreachable",
                detail: error.localizedDescription,
                fix: "Confirm the runner is still running (check Live Logs) and that its port matches the gateway's configured runner port."
            ))
        }
    }

    /// Sends an HTTP error response whose JSON body is derived from a
    /// `LocalMgrError`, and simultaneously records that same instance via
    /// `recordGatewayError` -- guaranteeing the developer-facing curl/IDE
    /// response body and the app's AppLog/Diagnostics/lastError banner are
    /// always built from one shared source of truth, never two independently
    /// worded messages.
    private func sendErrorResponse(connection: NWConnection, status: Int, error: LocalMgrError) {
        recordGatewayError(error)
        var errorDict: [String: Any] = ["message": error.message, "kind": error.kind]
        if let fix = error.fix { errorDict["fix"] = fix }
        if let detail = error.detail { errorDict["detail"] = detail }

        let jsonString: String
        if let data = try? JSONSerialization.data(withJSONObject: ["error": errorDict]),
           let str = String(data: data, encoding: .utf8) {
            jsonString = str
        } else {
            jsonString = "{\"error\":{\"message\":\"\(error.message)\"}}"
        }
        sendHTTPResponse(connection: connection, status: status, body: jsonString)
    }

    nonisolated private func sendHTTPResponse(connection: NWConnection, status: Int, body: String) {
        let statusText = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r
        \(body)
        """

        let data = Data(response.utf8)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
