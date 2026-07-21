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

    /// Hard cap on total accumulated request size (headers + body), to bound
    /// memory growth from a malicious or malformed client rather than
    /// reading forever. Comfortably larger than any legitimate coding-agent
    /// payload (OpenCode's full MCP tool-schema payloads have been observed
    /// well under 1MB) while still being a finite limit.
    nonisolated private static let maxRequestBytes = 25 * 1024 * 1024 // 25MB

    /// Per-read chunk size passed to `NWConnection.receive`. This is *not*
    /// a cap on total request size -- `accumulateRequest` loops additional
    /// reads until the full `Content-Length` body (or connection close) has
    /// been received, unlike the single-shot read this replaced (see
    /// `localmgr-ae9`: that single 64KB read silently truncated any larger
    /// POST body, corrupting its JSON before it ever reached the upstream
    /// engine).
    nonisolated private static let readChunkSize = 65536

    nonisolated private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        accumulateRequest(connection: connection, buffer: Data())
    }

    /// Reads from `connection` in a loop, accumulating bytes into `buffer`
    /// until either (a) the HTTP header terminator plus a `Content-Length`
    /// worth of body has been received, (b) the connection reports
    /// completion (no `Content-Length`, e.g. a bodyless GET), or (c)
    /// `maxRequestBytes` is exceeded. Replaces a prior single
    /// `connection.receive(maximumLength: 65536)` call that treated
    /// whatever arrived in one read as the complete request -- silently
    /// truncating any request whose headers + body exceeded 64KB (see
    /// `localmgr-ae9`).
    nonisolated private func accumulateRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunkSize) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }

            var newBuffer = buffer
            if let data = data, !data.isEmpty {
                newBuffer.append(data)
            }

            if newBuffer.isEmpty {
                connection.cancel()
                return
            }

            if newBuffer.count > Self.maxRequestBytes {
                Task {
                    await self.sendErrorResponse(connection: connection, status: 413, error: LocalMgrError(
                        message: "Request body exceeded the gateway's \(Self.maxRequestBytes / (1024 * 1024))MB limit.",
                        kind: "gateway-request-too-large"
                    ))
                }
                return
            }

            // Have we received the full header block yet?
            guard let headerEnd = newBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                // Headers incomplete -- keep reading (unless the peer already closed).
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                self.accumulateRequest(connection: connection, buffer: newBuffer)
                return
            }

            let headerData = newBuffer.subdata(in: newBuffer.startIndex..<headerEnd.lowerBound)
            let headerString = String(data: headerData, encoding: .utf8) ?? ""
            let contentLength = Self.parseContentLength(fromHeaders: headerString)
            let bodyBytesSoFar = newBuffer.count - headerEnd.upperBound

            let bodyComplete: Bool
            if let contentLength = contentLength {
                bodyComplete = bodyBytesSoFar >= contentLength
            } else {
                // No Content-Length (typical for a bodyless GET) -- the
                // header terminator itself marks the end of the request.
                bodyComplete = true
            }

            if bodyComplete {
                Task {
                    await self.incrementRequestCount()
                    await self.processHTTPRequest(data: newBuffer, connection: connection)
                }
                return
            }

            if isComplete || error != nil {
                // Peer closed before sending the full declared body --
                // forward what we have; downstream JSON parsing will
                // surface a clear malformed-request error rather than
                // hanging indefinitely.
                Task {
                    await self.incrementRequestCount()
                    await self.processHTTPRequest(data: newBuffer, connection: connection)
                }
                return
            }

            self.accumulateRequest(connection: connection, buffer: newBuffer)
        }
    }

    /// Case-insensitively extracts the `Content-Length` value from a raw
    /// HTTP header block, if present.
    nonisolated private static func parseContentLength(fromHeaders headers: String) -> Int? {
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Content-Length") == .orderedSame else {
                continue
            }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
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
        var isStreaming = false
        var jsonDict: [String: Any]?
        if let bodyData = bodyData,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            jsonDict = json
            requestedModelName = json["model"] as? String
            isStreaming = (json["stream"] as? Bool) ?? false
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

        var finalBodyData = bodyData
        if let activeModel = runner.activeModel, activeModel.engineType == .mlx {
            if var json = jsonDict {
                json["model"] = activeModel.fileURL.path
                if let reSerialized = try? JSONSerialization.data(withJSONObject: json, options: []) {
                    finalBodyData = reSerialized
                }
            }
        }

        let targetURL = URL(string: "http://127.0.0.1:\(runner.port)/v1/chat/completions")!
        var proxyReq = URLRequest(url: targetURL)
        proxyReq.httpMethod = "POST"
        proxyReq.httpBody = finalBodyData
        proxyReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        proxyReq.timeoutInterval = 1800.0

        // Mark this request as in-flight against the runner for the entire
        // duration of the upstream proxy call (streaming or buffered), so
        // `MemoryPressureGuard`'s warning-level `stopIfIdle` check can never
        // kill the runner mid-generation regardless of how long processing
        // takes -- see `localmgr-mtz` (the prior rolling-timestamp heuristic
        // only covered the first 3 seconds of a request).
        runner.beginRequest()
        defer { runner.endRequest() }

        if isStreaming {
            await proxyStreamingChatCompletion(proxyReq: proxyReq, runner: runner, connection: connection)
            return
        }

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
            recordCompletionTelemetry(
                runner: runner,
                ttftMs: durationMs * 0.2,
                durationMs: durationMs,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                cachedTokens: cachedTokens
            )

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

    /// Records completion telemetry for both `BackendRunnerManager` (drives
    /// `/v1/stats`) and `TelemetryStore` (drives `history.jsonl` + Ops
    /// Dashboard), shared by both the buffered and streaming chat-completion
    /// paths so the two proxy modes can never diverge in what they record.
    private func recordCompletionTelemetry(
        runner: BackendRunnerManager,
        ttftMs: Double,
        durationMs: Double,
        promptTokens: Int,
        completionTokens: Int,
        cachedTokens: Int
    ) {
        guard let active = runner.activeModel else { return }
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
            ttftMs: ttftMs,
            durationMs: durationMs,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedTokens: cachedTokens,
            thermalState: thState
        )
    }

    /// Proxies a `"stream": true` chat-completion request to the upstream
    /// engine (`llama-server` / `mlx_lm.server`) using `URLSession.bytes(for:)`
    /// so Server-Sent Events chunks are forwarded to the client incrementally
    /// as they arrive, instead of being buffered until the full generation
    /// completes (see `localmgr-al0.1`).
    ///
    /// Real time-to-first-token is measured from the first non-empty SSE
    /// `data:` line, replacing the `durationMs * 0.2` TTFT estimate used by
    /// the non-streaming path -- streaming lets us record a genuine TTFT
    /// rather than an approximation.
    private func proxyStreamingChatCompletion(proxyReq: URLRequest, runner: BackendRunnerManager, connection: NWConnection) async {
        let startTime = CFAbsoluteTimeGetCurrent()
        var firstChunkTime: Double?
        var completionTokens = 0
        var promptTokens = 0
        var cachedTokens = 0
        var headersSent = false

        do {
            let (byteStream, httpResp) = try await proxySession.bytes(for: proxyReq)
            let statusCode = (httpResp as? HTTPURLResponse)?.statusCode ?? 200

            guard statusCode == 200 else {
                // Upstream rejected the request outright (e.g. bad payload).
                // No SSE headers have been sent yet, so we can still reply
                // with a normal JSON error body.
                var errorBody = Data()
                for try await line in byteStream.lines {
                    errorBody.append(Data((line + "\n").utf8))
                }
                let bodyString = String(data: errorBody, encoding: .utf8) ?? ""
                
                var errorMessage = "The local engine rejected the streaming request."
                if !bodyString.isEmpty {
                    if let data = bodyString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errObj = json["error"] as? [String: Any],
                       let upstreamMsg = errObj["message"] as? String {
                        errorMessage = "The local engine rejected the streaming request: \(upstreamMsg)"
                    } else if bodyString.count < 200 {
                        errorMessage = "The local engine rejected the streaming request: \(bodyString.trimmingCharacters(in: .whitespacesAndNewlines))"
                    }
                }
                
                sendErrorResponse(connection: connection, status: statusCode, error: LocalMgrError(
                    message: errorMessage,
                    kind: "gateway-upstream-error",
                    detail: bodyString.isEmpty ? nil : bodyString
                ))
                return
            }

            sendSSEHeaders(connection: connection)
            headersSent = true

            for try await line in byteStream.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)

                if firstChunkTime == nil, !payload.isEmpty {
                    firstChunkTime = CFAbsoluteTimeGetCurrent()
                }

                if payload == "[DONE]" {
                    sendSSEChunk(connection: connection, line: line)
                    break
                }

                if let chunkData = payload.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] {
                    if let usage = json["usage"] as? [String: Any] {
                        completionTokens = usage["completion_tokens"] as? Int ?? completionTokens
                        promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
                        if let details = usage["prompt_tokens_details"] as? [String: Any] {
                            cachedTokens = details["cached_tokens"] as? Int ?? cachedTokens
                        }
                    }
                }

                sendSSEChunk(connection: connection, line: line)
            }

            closeSSEStream(connection: connection)

            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let ttftMs = firstChunkTime.map { ($0 - startTime) * 1000.0 } ?? durationMs
            if completionTokens == 0 {
                // Some engines omit a final `usage` chunk in streaming mode;
                // fall back to the same rough estimate the buffered path
                // uses when `usage` is absent.
                completionTokens = max(1, Int(durationMs / 4))
            }

            runner.recordTelemetry(ttftMs: ttftMs, durationMs: durationMs, completionTokens: completionTokens)
            recordCompletionTelemetry(
                runner: runner,
                ttftMs: ttftMs,
                durationMs: durationMs,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                cachedTokens: cachedTokens
            )
        } catch {
            if headersSent {
                // SSE headers (and likely some chunks) already went out --
                // we can no longer send a structured JSON error body without
                // corrupting the stream for the client. Log it and close.
                let isTimeout = (error as NSError).code == NSURLErrorTimedOut
                recordGatewayError(LocalMgrError(
                    message: isTimeout
                        ? "The streaming request to the local engine timed out mid-stream."
                        : "The streaming connection to the local engine was interrupted.",
                    kind: isTimeout ? "gateway-upstream-timeout" : "gateway-upstream-unreachable",
                    detail: error.localizedDescription,
                    fix: "Confirm the runner is still running (check Live Logs) and that its port matches the gateway's configured runner port."
                ))
                closeSSEStream(connection: connection)
            } else {
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

    /// Sends the initial HTTP response line + headers for a Server-Sent
    /// Events stream, leaving the connection open for subsequent
    /// `sendSSEChunk` calls (no `Content-Length`, `Connection: keep-alive`
    /// rather than the one-shot `sendHTTPResponse`'s `Connection: close`).
    nonisolated private func sendSSEHeaders(connection: NWConnection) {
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Connection: keep-alive\r
        Access-Control-Allow-Origin: *\r
        \r

        """
        connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
    }

    /// Sends a single already-framed SSE line (e.g. `data: {...}` or
    /// `data: [DONE]`) to the client, terminated with the SSE double
    /// newline. The connection is kept open for further chunks.
    nonisolated private func sendSSEChunk(connection: NWConnection, line: String) {
        let frame = line + "\n\n"
        connection.send(content: Data(frame.utf8), completion: .contentProcessed { _ in })
    }

    /// Closes an SSE connection after the stream has finished (either via a
    /// `[DONE]` sentinel or an upstream error mid-stream).
    nonisolated private func closeSSEStream(connection: NWConnection) {
        connection.send(content: nil, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
