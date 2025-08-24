import Foundation

struct AudioDevice: Identifiable, Hashable, Decodable {
    let id = UUID()
    let index: Int
    let name: String
}

@MainActor
final class TranscriptClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    // UI state
    @Published var devices: [AudioDevice] = []
    @Published var selectedDevice: AudioDevice?

    @Published var status: String = "Bağlı değil"
    @Published var isConnected: Bool = false
    @Published var autoAssist: Bool = true
    @Published var isDrafting: Bool = false

    // Streams
    @Published var partialEN: String = ""
    @Published var finalsEN: [String] = []
    @Published var partialTR: String = ""
    @Published var finalsTR: [String] = []

    // Assistant
    @Published var assistantEN: String = ""             // Önerilen yanıt (EN)
    @Published var lastDetectedQuestionEN: String = ""  // Backend’in yakaladığı soru

    // internals
    private var urlSession: URLSession!
    private var wsTask: URLSessionWebSocketTask?
    private var pingTimer: Timer?

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        urlSession = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }

    // MARK: - Endpoints
    private var startURL: URL? {
        if let s = Bundle.main.object(forInfoDictionaryKey: "BackendStartURL") as? String {
            return URL(string: s)
        }
        return nil
    }
    private var wsURL: URL? {
        if let s = Bundle.main.object(forInfoDictionaryKey: "BackendWSURL") as? String {
            return URL(string: s)
        }
        return nil
    }
    private var askURL: URL? {
        if let s = Bundle.main.object(forInfoDictionaryKey: "BackendAskURL") as? String {
            return URL(string: s)
        }
        return nil
    }
    var canAsk: Bool { askURL != nil }

    private var devicesURL: URL? {
        guard let startURL else { return nil }
        var comps = URLComponents(url: startURL, resolvingAgainstBaseURL: false)!
        comps.path = "/devices"
        return comps.url
    }

    // MARK: - Public
    func loadDevices() {
        guard let url = devicesURL else { return }
        var req = URLRequest(url: url); req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data else { return }
            struct DTO: Decodable { let index: Int; let name: String }
            if let arr = try? JSONDecoder().decode([DTO].self, from: data) {
                Task { @MainActor in
                    let devs = arr.map { AudioDevice(index: $0.index, name: $0.name) }
                    self.devices = devs
                    if self.selectedDevice == nil { self.selectedDevice = devs.first }
                }
            }
        }.resume()
    }

    func connect() {
        Task { await startPipeline() }  // /start tetikle (istersen kaldır)
        guard wsTask == nil, let url = wsURL else { status = "WS URL yok"; return }

        wsTask = urlSession.webSocketTask(with: url)
        wsTask?.resume()

        // Bağlanır bağlanmaz küçük bir selam gönder (server receive_text’i uyandırır)
        wsTask?.send(.string("hello")) { _ in }

        status = "Bağlantı kuruluyor…"
        receiveLoop()
        startPing()
    }

    func disconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        isConnected = false
        status = "Bağlantı kapalı"
    }

    /// Backend pipeline’ını başlat: cihaz + TR çeviri (+ varsa soru tespiti)
    func startPipeline() async {
        guard let startURL else { status = "StartURL yok"; return }
        var req = URLRequest(url: startURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "device": selectedDevice?.name as Any,  // örn: "BlackHole 2ch"
            "translate_to": "tr"
            // "lang": "en", // istersen sabitle
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        do { _ = try await URLSession.shared.data(for: req) } catch {
            status = "start hata: \(error.localizedDescription)"
        }
    }

    // Elle tetikleme (buton): bağlamla /ask
    func askAssistant(questionEN: String? = nil) async {
        guard let askURL, !isDrafting else { return }
        isDrafting = true; defer { isDrafting = false }

        let q = (questionEN?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? lastDetectedQuestionEN
            ?? ""

        // Bağlam: son birkaç EN/TR final cümle
        let ctxEN = finalsEN.suffix(12).joined(separator: "\n")
        let ctxTR = finalsTR.suffix(12).joined(separator: "\n")

        var req = URLRequest(url: askURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "question": q,
            "context_en": ctxEN,
            "context_tr": ctxTR,
            "target": "en"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let answer = (obj["answer"] as? String) ?? (obj["text"] as? String) {
                assistantEN = answer
            } else {
                assistantEN = String(data: data, encoding: .utf8) ?? ""
            }
        } catch {
            assistantEN = "[ask error] \(error.localizedDescription)"
        }
    }

    // MARK: - WS
    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                self.isConnected = true
                self.status = "Bağlı"
                switch msg {
                case .string(let s): self.handleJSON(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { self.handleJSON(s) }
                @unknown default: break
                }
                self.receiveLoop()
            case .failure(let err):
                self.appendFinalEN("[ws kapandı] \(err.localizedDescription)")
                self.scheduleReconnect()
            }
        }
    }

    private func startPing() {
        // 20 sn’de bir ping + küçük metin; bazı ağlarda idle kapanmayı engeller
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, let ws = self.wsTask else { return }
            ws.sendPing { _ in }
            ws.send(.string("ping"), completionHandler: { _ in })
        }
    }

    private func scheduleReconnect() {
        disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.connect()
        }
    }

    private func handleJSON(_ s: String) {
        // Beklenenler:
        // {"type":"partial","en":"...","tr":"..."}
        // {"type":"final","en":"...","tr":"..."}
        // {"type":"partial","text":"..."}  // TR varsay
        // {"type":"qa.question","en":"...","tr":"..."}
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        let en = (obj["en"] as? String)
        let tr = (obj["tr"] as? String) ?? (obj["text"] as? String)

        switch type {
        case "partial":
            if let en { partialEN = en }
            if let tr { partialTR = tr }
        case "final":
            if let en { appendFinalEN(en) }
            if let tr { appendFinalTR(tr) }
            partialEN = ""; partialTR = ""
        case "error":
            let msg = (obj["text"] as? String) ?? "error"
            appendFinalEN("[error] \(msg)")
        case "info":
            let msg = (obj["text"] as? String) ?? "info"
            appendFinalEN("[info] \(msg)")
        case "qa.question":
            if let enQ = en { lastDetectedQuestionEN = enQ }
            if autoAssist { Task { await askAssistant() } }
        default:
            break
        }
    }

    private func appendFinalEN(_ line: String) {
        finalsEN.append(line)
        if finalsEN.count > 600 { finalsEN.removeFirst(finalsEN.count - 600) }
    }
    private func appendFinalTR(_ line: String) {
        finalsTR.append(line)
        if finalsTR.count > 600 { finalsTR.removeFirst(finalsTR.count - 600) }
    }

    // MARK: - URLSessionWebSocketDelegate

    // 1) WS açıldı: bağlandığını işaretle + “hello”
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol `protocol`: String?) {
        isConnected = true
        status = "WS açık"
        webSocketTask.send(.string("hello")) { _ in }
    }

    // 2) WS kapandı: nedenini logla ve yeniden bağlan
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            appendFinalEN("[ws complete] \(error.localizedDescription)")
        } else {
            appendFinalEN("[ws complete] normal")
        }
        scheduleReconnect()
    }

    // 3) Server kapattıysa (close code) — yine reconnect
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        appendFinalEN("[ws didClose] code=\(closeCode.rawValue)")
        scheduleReconnect()
    }
}
