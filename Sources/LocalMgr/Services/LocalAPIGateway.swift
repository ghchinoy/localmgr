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

    func configure(catalog: ModelCatalogService, runner: BackendRunnerManager) {
        self.catalog = catalog
        self.runner = runner
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
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastLog = "Gateway error: \(error.localizedDescription)"
                    case .cancelled:
                        self?.isRunning = false
                        self?.lastLog = "Gateway stopped"
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
        }
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

        await updateLastLog("\(method) \(path)")
        await runner?.recordActivity()

        if method == "GET" && (path == "/v1/models" || path == "/models") {
            await handleModelsList(connection: connection)
        } else if method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions") {
            await handleChatCompletions(rawRequest: data, requestString: requestString, connection: connection)
        } else {
            sendHTTPResponse(connection: connection, status: 404, body: "{\"error\":\"Endpoint not found on LocalMgr Gateway\"}")
        }
    }

    private func handleModelsList(connection: NWConnection) async {
        guard let catalog = catalog else { return }
        let modelsArray = catalog.models.map { model in
            [
                "id": model.name,
                "object": "model",
                "created": Int(Date().timeIntervalSince1970),
                "owned_by": "localmgr"
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

    private func handleChatCompletions(rawRequest: Data, requestString: String, connection: NWConnection) async {
        guard let runner = runner, let catalog = catalog else {
            sendHTTPResponse(connection: connection, status: 500, body: "{\"error\":\"Gateway not initialized\"}")
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
                updateLastLog("On-demand wake: starting \(matched.name)...")
                runner.startModel(matched)
                
                for _ in 0..<30 {
                    if runner.status == .running { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        guard runner.status == .running || runner.activeModel != nil else {
            sendHTTPResponse(connection: connection, status: 503, body: "{\"error\":\"No local model runner active or ready on port \(runner.port)\"}")
            return
        }

        let targetURL = URL(string: "http://127.0.0.1:\(runner.port)/v1/chat/completions")!
        var proxyReq = URLRequest(url: targetURL)
        proxyReq.httpMethod = "POST"
        proxyReq.httpBody = bodyData
        proxyReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (respData, httpResp) = try await URLSession.shared.data(for: proxyReq)
            let statusCode = (httpResp as? HTTPURLResponse)?.statusCode ?? 200
            if let respString = String(data: respData, encoding: .utf8) {
                sendHTTPResponse(connection: connection, status: statusCode, body: respString)
            } else {
                sendHTTPResponse(connection: connection, status: 502, body: "{\"error\":\"Invalid response encoding from backend\"}")
            }
        } catch {
            sendHTTPResponse(connection: connection, status: 502, body: "{\"error\":\"Proxy error: \(error.localizedDescription)\"}")
        }
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
