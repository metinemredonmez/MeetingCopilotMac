//
//  RealtimeStreamer.swift
//  MeetingCopilotMac
//
//  Created by emre on 24.08.2025.
//

import Foundation
import AVFoundation

@MainActor
final class RealtimeStreamer: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    enum WireFormat { case binaryPCM, jsonBase64 }

    @Published var status: String = "Hazır"
    @Published var serverMessages: [String] = []

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var wsTask: URLSessionWebSocketTask?
    private var session: URLSession!
    private var pingTimer: Timer?

    private let outFormat: AVAudioFormat
    private let wireFormat: WireFormat = .binaryPCM   // İstersen .jsonBase64 yap

    private var isRunning = false

    override init() {
        // 16 kHz, mono, PCM16, interleaved
        outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                  sampleRate: 16_000,
                                  channels: 1,
                                  interleaved: true)!
        super.init()
        let cfg = URLSessionConfiguration.default
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }

    // MARK: - Public API
    func start() {
        guard !isRunning else { return }
        Task { @MainActor in
            do {
                try await requestMicPermission()
                try await startBackendSessionIfConfigured()  // /start
                try startWebSocket()
                try startAudio()
                isRunning = true
                status = "Stream başlatıldı"
            } catch {
                status = "Hata: \(error.localizedDescription)"
                stop()
            }
        }
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        converter = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        pingTimer?.invalidate()
        pingTimer = nil
        isRunning = false
        status = "Durduruldu"
    }

    // MARK: - Permissions
    private func requestMicPermission() async throws {
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        if !granted { throw NSError(domain: "Mic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mikrofon izni verilmedi"]) }
    }

    // MARK: - Backend session (/start)
    private func startBackendSessionIfConfigured() async throws {
        guard let startURLString = Bundle.main.object(forInfoDictionaryKey: "BackendStartURL") as? String,
              let url = URL(string: startURLString) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: req) // Body gerekmiyorsa yeterli
    }

    // MARK: - WebSocket
    private func startWebSocket() throws {
        guard let wsURLString = Bundle.main.object(forInfoDictionaryKey: "BackendWSURL") as? String,
              let url = URL(string: wsURLString) else {
            throw NSError(domain: "WS", code: 1, userInfo: [NSLocalizedDescriptionKey: "BackendWSURL bulunamadı"])
        }
        wsTask = session.webSocketTask(with: url)
        wsTask?.resume()
        receiveLoop()
        startPing()
    }

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.wsTask?.sendPing { err in
                if let err { print("Ping error:", err) }
            }
        }
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let s): self.serverMessages.append(s); self.status = "Mesaj alındı"
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) {
                        self.serverMessages.append(s)
                    } else {
                        self.serverMessages.append("<<binary \(d.count)B>>")
                    }
                @unknown default:
                    break
                }
                self.receiveLoop() // devam
            case .failure(let error):
                self.status = "WS kapandı: \(error.localizedDescription)"
                // Oturum 30 dk limitine takıldıysa otomatik yeniden başlat
                Task { @MainActor in
                    try? await self.startBackendSessionIfConfigured()
                    self.restartWebSocketAfterDelay()
                }
            }
        }
    }

    private func restartWebSocketAfterDelay() {
        // küçük gecikme
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            do { try self.startWebSocket() } catch {
                self.status = "WS yeniden başlatılamadı: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Audio
    private func startAudio() throws {
        let input = engine.inputNode
        let inFmt = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFmt, to: outFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }

            let cap = AVAudioFrameCount(self.outFormat.sampleRate * 0.1) // ~100ms
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: cap) else { return }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            let _ = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
            if error != nil { return }

            guard let ch = outBuf.int16ChannelData else { return }
            let frameCount = Int(outBuf.frameLength)
            // Interleaved olduğumuz için tek kanalın verisi tüm veridir:
            let byteCount = frameCount * MemoryLayout<Int16>.size
            let data = Data(bytes: ch[0], count: byteCount)
            self.sendFrame(data: data)
        }

        engine.prepare()
        try engine.start()
    }

    private func sendFrame(data: Data) {
        guard let wsTask else { return }
        switch wireFormat {
        case .binaryPCM:
            wsTask.send(.data(data)) { err in
                if let err { print("WS send error:", err) }
            }
        case .jsonBase64:
            let b64 = data.base64EncodedString()
            let payload: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": b64,
                "format": "pcm16",
                "sample_rate_hz": 16_000
            ]
            if let json = try? JSONSerialization.data(withJSONObject: payload),
               let str = String(data: json, encoding: .utf8) {
                wsTask.send(.string(str)) { err in
                    if let err { print("WS send error:", err) }
                }
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        status = "WS kapandı (\(closeCode.rawValue))"
        Task { @MainActor in
            try? await self.startBackendSessionIfConfigured()
            self.restartWebSocketAfterDelay()
        }
    }
}

