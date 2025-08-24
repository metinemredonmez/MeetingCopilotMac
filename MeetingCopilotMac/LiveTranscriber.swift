//
//  LiveTranscriber.swift
//  MeetingCopilotMac
//
//  Created by emre on 24.08.2025.
//

import Foundation
import AVFoundation
import Speech

@MainActor
final class LiveTranscriber: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRunning: Bool = false
    @Published var statusText: String = "Hazır"

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))

    func start() {
        guard !isRunning else { return }
        Task { @MainActor in
            do {
                try await requestPermissions()
                try startAudioAndRecognition()
                statusText = "Dinliyor…"
                isRunning = true
            } catch {
                statusText = "Hata: \(error.localizedDescription)"
                stop()
            }
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRunning = false
        if statusText.hasPrefix("Dinliyor") { statusText = "Hazır" }
    }

    private func requestPermissions() async throws {
        // Speech izni
        let speechAuth = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speechAuth == .authorized else {
            throw NSError(domain: "SpeechAuth", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech izni verilmedi"])
        }

        // Mikrofon izni
        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        guard micGranted else {
            throw NSError(domain: "MicAuth", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Mikrofon izni verilmedi"])
        }
    }

    private func startAudioAndRecognition() throws {
        let input = audioEngine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.request = req

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let r = result {
                self.transcript = r.bestTranscription.formattedString
                if r.isFinal {
                    self.statusText = "Bitti (final)"
                    self.stop()
                }
            }
            if let e = error {
                self.statusText = "Tanıma hatası: \(e.localizedDescription)"
                self.stop()
            }
        }
    }

    // İstersen Info.plist’e "BackendIngestURL" ekleyip buradan okuyabilirsin.
    func sendToBackend(text: String) async {
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "BackendIngestURL") as? String,
            let url = URL(string: urlString),
            !text.isEmpty
        else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["text": text]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        do { _ = try await URLSession.shared.data(for: req) } catch { /* sessiz geç */ }
    }
}

