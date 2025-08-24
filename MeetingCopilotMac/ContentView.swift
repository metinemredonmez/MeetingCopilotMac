import SwiftUI

struct ContentView: View {
    @StateObject private var client = TranscriptClient()
    @State private var manualQuestion: String = ""

    var body: some View {
        VStack(spacing: 12) {
            // Controls
            HStack(spacing: 12) {
                Picker("Cihaz:", selection: $client.selectedDevice) {
                    ForEach(client.devices) { dev in
                        Text(dev.name).tag(Optional(dev))
                    }
                }
                .frame(width: 260)

                Button(client.isConnected ? "Durdur" : "Başlat") {
                    client.isConnected ? client.disconnect() : client.connect()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Cihazları Yenile") { client.loadDevices() }

                Toggle("Auto Assist", isOn: $client.autoAssist)
                    .toggleStyle(.switch)
                    .help("Soru tespit edilince otomatik yanıt taslağı üret")

                Spacer()
                Text("Durum: \(client.status)")
                    .foregroundStyle(.secondary)
            }

            // 3 sütun
            HStack(alignment: .top, spacing: 12) {
                // EN column
                VStack(alignment: .leading, spacing: 8) {
                    GroupBox("English – Live") {
                        Text(client.partialEN.isEmpty ? "—" : client.partialEN)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .animation(.default, value: client.partialEN)
                    }
                    .frame(minHeight: 70)
                    .frame(maxWidth: .infinity)

                    GroupBox("English – Final") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(client.finalsEN.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(8)
                        }
                        .frame(minHeight: 220)
                        .frame(maxWidth: .infinity)   // << genişlet
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(minWidth: 320, maxWidth: .infinity) // << sütunu genişlet
                .layoutPriority(1)

                // TR column
                VStack(alignment: .leading, spacing: 8) {
                    GroupBox("Türkçe – Anlık Çeviri") {
                        Text(client.partialTR.isEmpty ? "—" : client.partialTR)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .animation(.default, value: client.partialTR)
                    }
                    .frame(minHeight: 70)
                    .frame(maxWidth: .infinity)

                    GroupBox("Türkçe – Final Altyazı") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(client.finalsTR.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(8)
                        }
                        .frame(minHeight: 220)
                        .frame(maxWidth: .infinity)   // << genişlet
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(minWidth: 320, maxWidth: .infinity) // << sütunu genişlet
                .layoutPriority(1)

                // Assistant column
                VStack(alignment: .leading, spacing: 8) {
                    GroupBox("Asistan – Algılanan Soru (EN)") {
                        Text(client.lastDetectedQuestionEN.isEmpty ? "—" : client.lastDetectedQuestionEN)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }

                    GroupBox("Asistan – Yanıt Taslağı (EN)") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Manuel soru (EN)…", text: $manualQuestion)
                                    .textFieldStyle(.roundedBorder)
                                Button("Yanıt Öner") {
                                    Task { await client.askAssistant(questionEN: manualQuestion) }
                                }
                                .disabled(!client.canAsk || client.isDrafting)
                                if client.isDrafting { ProgressView().scaleEffect(0.8) }
                            }

                            ScrollView {
                                Text(client.assistantEN.isEmpty ? "—" : client.assistantEN)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }

                            HStack {
                                Button("Kopyala") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(client.assistantEN, forType: .string)
                                }
                                .disabled(client.assistantEN.isEmpty)
                                Spacer()
                                Button("Temizle") {
                                    client.assistantEN = ""
                                    manualQuestion = ""
                                }
                            }
                        }
                        .padding(6)
                    }
                }
                .frame(minWidth: 300, maxWidth: 380) // sağ kolon dar/sabit
            }
            .frame(maxWidth: .infinity) // HStack yayılsın

            HStack {
                Button("Tümünü Temizle") {
                    client.partialEN = ""; client.partialTR = ""
                    client.finalsEN.removeAll(); client.finalsTR.removeAll()
                    client.assistantEN = ""; client.lastDetectedQuestionEN = ""
                }
                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 1080, minHeight: 620)
        .onAppear { client.loadDevices() }
    }
}

#Preview { ContentView() }
