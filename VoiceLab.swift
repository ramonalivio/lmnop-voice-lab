import SwiftUI
import AVFoundation

let readingPassage = "Today I am testing my own voice. I would like to speak clearly and naturally, at a comfortable pace. Tomorrow, I plan to call a friend and talk about our plans for the weekend."

@MainActor final class VoiceModel: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    @Published var status = "Starting local voice engine…"
    @Published var ready = false
    @Published var busy = true
    @Published var recording = false
    @Published var hasReference = false
    @Published var hasOutput = false
    @Published var seconds = 0.0
    @Published var level = 0.0
    @Published var text = "Kumusta! Sinusubukan ko ang aking boses. Sana ay maganda ang araw mo."
    @Published var language = "Tagalog"
    @Published var error = false
    @Published var pendingPermission = false
    @Published var recordingSpeech = false
    @Published var transcript = ""
    @Published var translation = ""
    @Published var timing = ""
    @Published var waveform: [Float] = []
    @Published var outputDuration = 0.0
    @Published var playbackPosition = 0.0
    @Published var playingOutput = false
    private var playbackTimer: Timer?
    private var stoppedAt: TimeInterval?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var process: Process?
    private var input: Pipe?
    private var timer: Timer?
    private var quitting = false
    let root: URL
    var data: URL { root.appendingPathComponent(".local-data") }

    override init() {
        root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "VoiceLabSourceRoot") as! String)
        super.init()
        do { try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { fail("Unable to create local storage: \(error.localizedDescription)"); return }
        hasReference = FileManager.default.fileExists(atPath: data.appendingPathComponent("reference.wav").path)
        if FileManager.default.fileExists(atPath: data.appendingPathComponent("speech.wav").path) { loadWaveform() }
        startWorker()
    }
    func startWorker() {
        let p = Process(); let stdin = Pipe(); let stdout = Pipe()
        p.executableURL = root.appendingPathComponent(".venv/bin/python")
        p.arguments = ["-u", root.appendingPathComponent("worker.py").path]
        p.currentDirectoryURL = root
        p.standardInput = stdin; p.standardOutput = stdout
        let log = data.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        p.standardError = try? FileHandle(forWritingTo: log)
        p.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self, !self.quitting else { return }
                self.ready = false
                self.fail("Voice engine stopped (\(p.terminationStatus)). Quit and reopen the app; details are in engine.log.")
            }
        }
        do {
            try p.run(); process = p; input = stdin
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var pending = Data()
                while true {
                    let chunk = stdout.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending.prefix(upTo: newline)
                        pending.removeSubrange(...newline)
                        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        Task { @MainActor [weak self] in self?.handle(object) }
                    }
                }
            }
        } catch { fail("Could not start local engine: \(error.localizedDescription)") }
    }
    func handle(_ event: [String: Any]) {
        let kind = event["event"] as? String ?? ""
        status = event["message"] as? String ?? kind
        error = kind == "error" || kind == "fatal"
        switch kind {
        case "ready": ready = true; busy = false; if hasReference { status = "Ready. Speak English to hear Spanish, or type text below." }
        case "reference": hasReference = true; busy = false
        case "generated":
            busy = false; loadWaveform()
            if !error { status = "Audio ready. Press Play generated audio to listen." }
            if event["mode"] as? String == "translate_speech", !error {
                let elapsed = ProcessInfo.processInfo.systemUptime - (stoppedAt ?? ProcessInfo.processInfo.systemUptime)
                let stages = event["timings"] as? [String: Double] ?? [:]
                timing = String(format: "Stop → audio ready: %.2fs · Recognition %.2fs · Translation %.2fs · Voice %.2fs", elapsed, stages["recognition"] ?? 0, stages["translation"] ?? 0, stages["synthesis"] ?? 0)
                status = "Spanish translation is ready. Press Play generated audio to listen."
            }
            stoppedAt = nil
        case "transcript": transcript = event["transcript"] as? String ?? ""
        case "translation": translation = event["translation"] as? String ?? ""
        case "error", "fatal": busy = false
        case "loading", "generating", "transcribing": busy = true
        default: break
        }
    }
    func fail(_ message: String) { status = message; error = true; busy = false }
    func send(_ object: [String: Any]) {
        guard let process, process.isRunning, let input else { fail("The local voice engine is not running."); return }
        do {
            var payload = try JSONSerialization.data(withJSONObject: object); payload.append(10)
            try input.fileHandleForWriting.write(contentsOf: payload)
        } catch { fail(error.localizedDescription) }
    }
    func record(speech: Bool = false) {
        guard ready, !busy, !recording, !pendingPermission else { return }
        error = false; pendingPermission = true; status = "Allow microphone access when macOS asks."
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            Task { @MainActor in
                self.pendingPermission = false
                guard allowed else { self.fail("Microphone access is off. Enable Voice Lab in System Settings → Privacy & Security → Microphone, then try again."); return }
                self.beginRecording(speech: speech)
            }
        }
    }
    func beginRecording(speech: Bool) {
        stopPlayback()
        do {
            recorder = try AVAudioRecorder(url: data.appendingPathComponent(speech ? "utterance.wav" : "pending.wav"), settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            recorder!.delegate = self; recorder!.isMeteringEnabled = true
            guard recorder!.record() else { fail("Could not start the microphone."); return }
            recordingSpeech = speech; recording = true; seconds = 0
            if speech { transcript = ""; translation = ""; timing = ""; clearOutput() }
            status = speech ? "Speak English. Press Stop & translate when finished." : "Read the passage naturally. Press Stop when you finish."
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder, self.recording else { return }
                    self.seconds = recorder.currentTime; recorder.updateMeters()
                    self.level = min(1, max(0, (Double(recorder.averagePower(forChannel: 0)) + 55) / 55))
                    if self.seconds >= 30 { self.stopRecording() }
                }
            }
        } catch { fail("Recording failed: \(error.localizedDescription)") }
    }
    func stopRecording() {
        guard recording else { return }
        recording = false; recorder?.stop(); timer?.invalidate(); timer = nil; level = 0
        busy = true; status = "Checking your recording…"
        if recordingSpeech {
            stoppedAt = ProcessInfo.processInfo.systemUptime
            send(["action": "translate_speech"])
        } else { send(["action": "reference"]) }
        recordingSpeech = false
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.recording = false; self.timer?.invalidate(); self.fail(error?.localizedDescription ?? "Recording error. Please try again.") }
    }
    func speak() {
        guard ready, !busy, !recording, hasReference else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 600 else { fail("Type between 1 and 600 characters."); return }
        stopPlayback(); clearOutput(); busy = true; error = false; status = "Generating speech in your voice…"
        send(["action": "generate", "text": value, "language": language])
    }
    func clearOutput() {
        hasOutput = false; waveform = []; outputDuration = 0; playbackPosition = 0
    }
    func loadWaveform() {
        clearOutput()
        do {
            let file = try AVAudioFile(forReading: data.appendingPathComponent("speech.wav"))
            guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw NSError(domain: "VoiceLab", code: 1) }
            try file.read(into: buffer)
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { throw NSError(domain: "VoiceLab", code: 2) }
            let count = Int(buffer.frameLength)
            let bins = min(120, count)
            var peaks = [Float](repeating: 0, count: bins)
            for bin in 0..<bins {
                for frame in (bin * count / bins)..<((bin + 1) * count / bins) {
                    for channel in 0..<Int(buffer.format.channelCount) {
                        peaks[bin] = max(peaks[bin], abs(channels[channel][frame]))
                    }
                }
            }
            let peak = max(peaks.max() ?? 0, 0.001)
            waveform = peaks.map { $0 / peak }
            outputDuration = Double(count) / buffer.format.sampleRate
            hasOutput = true
        } catch { fail("Unable to read generated audio: \(error.localizedDescription)") }
    }
    func stopPlayback() {
        player?.stop(); playbackTimer?.invalidate(); playbackTimer = nil; playingOutput = false
    }
    func toggleOutput() {
        if playingOutput { stopPlayback(); playbackPosition = 0 }
        else { play("speech.wav") }
    }
    func play(_ name: String) {
        stopPlayback()
        do {
            player = try AVAudioPlayer(contentsOf: data.appendingPathComponent(name))
            player?.delegate = self
            guard player?.play() == true else { fail("Audio playback failed."); return }
            if name == "speech.wav" {
                playbackPosition = 0; playingOutput = true
                playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.playingOutput else { return }
                        self.playbackPosition = self.player?.currentTime ?? 0
                    }
                }
            }
        } catch { fail("Unable to play audio: \(error.localizedDescription)") }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.playingOutput { self.playbackPosition = self.outputDuration }
            self.playingOutput = false; self.playbackTimer?.invalidate(); self.playbackTimer = nil
            if !flag { self.fail("Audio playback did not finish successfully.") }
        }
    }
    func shutdown() {
        quitting = true; timer?.invalidate(); recorder?.stop(); stopPlayback()
        try? input?.fileHandleForWriting.close()
        process?.terminate()
    }
}

struct WaveformView: View {
    let peaks: [Float]
    let progress: Double
    var body: some View {
        Canvas { context, size in
            if peaks.isEmpty {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(line, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
            } else {
                let step = size.width / CGFloat(peaks.count)
                for (index, peak) in peaks.enumerated() {
                    let height = max(2, CGFloat(peak) * (size.height - 8))
                    let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: max(1, step - 2), height: height)
                    let played = Double(index) / Double(peaks.count) < progress
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(played ? .accentColor : .secondary.opacity(0.35)))
                }
            }
        }
    }
}

struct VoiceView: View {
    @ObservedObject var model: VoiceModel
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Voice Lab").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Your words. Your voice. On your Mac.").foregroundStyle(.secondary)
                }
                Spacer()
                Label("LOCAL", systemImage: "desktopcomputer").font(.caption.bold()).padding(9).background(.green.opacity(0.12), in: Capsule())
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Speak English → hear Spanish").font(.headline)
                    Text("Click Start, say a short English phrase, then click Stop & translate. Uses your saved voice and runs offline.").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(action: { model.recordingSpeech ? model.stopRecording() : model.record(speech: true) }) {
                            Label(model.recordingSpeech ? "Stop & translate" : "Start speaking English", systemImage: model.recordingSpeech ? "stop.fill" : "mic.fill")
                        }.buttonStyle(.borderedProminent).tint(model.recordingSpeech ? .red : .accentColor)
                        .disabled(!model.ready || !model.hasReference || model.busy || model.pendingPermission || (model.recording && !model.recordingSpeech))
                        if model.recordingSpeech { Text(String(format: "%.1f / 30s", model.seconds)).monospacedDigit() }
                    }
                    if model.recordingSpeech { ProgressView(value: model.level).tint(.red) }
                    if !model.transcript.isEmpty { Text("English: " + model.transcript).textSelection(.enabled) }
                    if !model.translation.isEmpty { Text("Spanish: " + model.translation).fontWeight(.medium).textSelection(.enabled) }
                    if !model.timing.isEmpty { Text(model.timing).font(.caption).monospacedDigit().textSelection(.enabled) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Latest generated audio").font(.caption).foregroundStyle(.secondary)
                        WaveformView(peaks: model.waveform, progress: model.outputDuration > 0 ? model.playbackPosition / model.outputDuration : 0)
                            .frame(height: 64).accessibilityLabel(model.hasOutput ? "Generated audio waveform" : "Waveform appears when audio is ready")
                        HStack {
                            Button(action: model.toggleOutput) {
                                Label(model.playingOutput ? "Stop playback" : "Play generated audio", systemImage: model.playingOutput ? "stop.fill" : "play.fill")
                            }.disabled(!model.hasOutput || model.busy || model.recording)
                            Text(String(format: "%.1f / %.1f s", model.playbackPosition, model.outputDuration)).font(.caption).monospacedDigit()
                            Spacer()
                            Text("Plays only when you press Play").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Text("1  Read this aloud").font(.headline)
                    Text(readingPassage).font(.system(size: 17)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("Use a quiet room and your normal voice. Read the whole passage exactly as written (about 15 seconds).").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button(action: { model.recording ? model.stopRecording() : model.record() }) {
                            Label(model.recording ? "Stop recording" : (model.hasReference ? "Record again" : "Record my voice"), systemImage: model.recording ? "stop.fill" : "mic.fill")
                        }.buttonStyle(.borderedProminent).tint(model.recording ? .red : .accentColor)
                            .disabled(model.recordingSpeech || ((model.busy || !model.ready || model.pendingPermission) && !model.recording))
                        Button("Play my recording") { model.play("reference.wav") }.disabled(!model.hasReference || model.recording || model.busy)
                        Spacer()
                        if model.recording { Text(String(format: "%.1f / 30s", model.seconds)).monospacedDigit().foregroundStyle(.red) }
                        else if model.hasReference { Label("Voice saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    if model.recording { ProgressView(value: model.level).tint(.red) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("2  Type something to say").font(.headline)
                        Spacer()
                        Picker("Language", selection: $model.language) { Text("English").tag("English"); Text("Tagalog").tag("Tagalog"); Text("Spanish").tag("Spanish") }.frame(width: 210).disabled(model.busy || model.recording)
                    }
                    TextEditor(text: $model.text).font(.system(size: 17)).frame(height: 105).padding(8).background(.background, in: RoundedRectangle(cornerRadius: 8)).disabled(model.busy || model.recording)
                    HStack {
                        Text("\(model.text.count)/600 characters · Reads your text; does not translate it.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Spanish example") { model.language = "Spanish"; model.text = "Hola, me gustaría reservar una mesa para dos personas. Muchas gracias." }.disabled(model.busy || model.recording)
                        Button("Tagalog example") { model.language = "Tagalog"; model.text = "Kumusta! Gusto kong magpareserba ng mesa para sa dalawang tao bukas ng alas otso ng gabi. Maraming salamat." }.disabled(model.busy || model.recording)
                    }
                    HStack {
                        Button(action: model.speak) { Label("Generate in my voice", systemImage: "waveform") }.buttonStyle(.borderedProminent).disabled(!model.ready || !model.hasReference || model.busy || model.recording || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.text.count > 600)
                        Button("Replay") { model.play("speech.wav") }.disabled(!model.hasOutput || model.busy || model.recording)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).foregroundStyle(model.error ? .red : .secondary).textSelection(.enabled)
            }.frame(minHeight: 25)
            Text("Your sample and generated speech stay on this Mac. Voice similarity and generation time will vary.").font(.caption).foregroundStyle(.secondary)
        }.padding(26)
        }.frame(width: 800, height: 850).onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
    }
}

@main struct VoiceLabApp: App {
    @StateObject private var model = VoiceModel()
    var body: some Scene {
        Window("Voice Lab", id: "main") { VoiceView(model: model) }
            .windowResizability(.contentSize)
    }
}
