import AltyaziCore
import AVFoundation
import Speech

/// Oyunun sesindeki konuşmayı cihaz üstünde yazıya döker (altyazısı olmayan oyunlar için).
///
/// PS5'ten gelen ses (Opus) çözülür, konuşma tanıyıcıya verilir; tanıyıcının akan dökümü cümlelere
/// bölünür ve her cümle bir kez `onUtterance` ile bildirilir. Ses cihazdan dışarı çıkmaz.
///
/// DENEYSEL: müzik ve efekt seslerinin arasında tanıma her zaman doğru olmaz.
final class SpeechListener: @unchecked Sendable {
    /// Bitmiş bir cümle (İngilizce). Tanıyıcının kuyruğunda çağrılır.
    var onUtterance: ((String) -> Void)?

    private let queue = DispatchQueue(label: "altyazitr.speech")
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var decoder: AVAudioConverter?
    private var resampler: AVAudioConverter?
    private var opusFormat: AVAudioFormat?
    private var decodedFormat: AVAudioFormat?
    private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var frameSize: AVAudioFrameCount = 480
    private var segmenter = UtteranceSegmenter()
    private var timer: DispatchSourceTimer?
    private var running = false
    private var taskStarted = Date.distantPast
    private var generation = 0

    // Teşhis
    private var _status = "kapalı"
    private var _lastHeard = ""
    private var _utterances = 0
    var status: String { queue.sync { _status } }
    var lastHeard: String { queue.sync { _lastHeard } }
    var utterances: Int { queue.sync { _utterances } }

    /// Dinlemeyi başlatır; ilk kez çağrıldığında konuşma tanıma izni istenir.
    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
            guard let self else { return }
            self.queue.async {
                guard authorization == .authorized else {
                    self._status = "izin verilmedi"
                    return
                }
                guard let recognizer = self.recognizer, recognizer.supportsOnDeviceRecognition else {
                    self._status = "bu cihaz cihaz üstü İngilizce konuşma tanımayı desteklemiyor"
                    return
                }
                self.running = true
                self._status = "ses bekleniyor"
                self.startTimer()
            }
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            self.endTask()
            self._status = "kapalı"
        }
    }

    /// Ses biçimi PS5'ten geldiğinde çağrılır.
    func configure(channels: Int, sampleRate: Int, frameSize: Int) {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(frameSize), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
              let decoded = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels)) else { return }
        queue.async {
            self.opusFormat = input
            self.decodedFormat = decoded
            self.decoder = AVAudioConverter(from: input, to: decoded)
            self.resampler = AVAudioConverter(from: decoded, to: self.speechFormat)
            self.frameSize = AVAudioFrameCount(frameSize)
        }
    }

    /// Tek bir Opus paketi. PS5'in ses iş parçacığından çağrılır.
    func enqueue(_ packet: UnsafeBufferPointer<UInt8>) {
        let data = Data(buffer: packet)
        queue.async { self.process(data) }
    }

    // MARK: - (tümü `queue` üzerinde)

    private func process(_ packet: Data) {
        guard running, let decoder, let resampler, let opusFormat, let decodedFormat else { return }
        let compressed = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        guard let decoded = AVAudioPCMBuffer(pcmFormat: decodedFormat, frameCapacity: frameSize + 64),
              convert(decoder, from: compressed, to: decoded),
              let speech = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: frameSize),
              convert(resampler, from: decoded, to: speech) else { return }

        if request == nil { beginTask() }
        request?.append(speech)
    }

    private func convert(_ converter: AVAudioConverter, from input: AVAudioBuffer, to output: AVAudioPCMBuffer) -> Bool {
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        return status != .error && output.frameLength > 0
    }

    private func beginTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true     // ses cihazdan çıkmaz
        request.addsPunctuation = true
        request.taskHint = .dictation
        self.request = request
        segmenter.reset()
        taskStarted = Date()
        generation += 1
        let mine = generation
        _status = "dinliyor"
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                guard mine == self.generation else { return }   // eski görevin geç gelen sonucu
                if let result {
                    let text = result.bestTranscription.formattedString
                    self._lastHeard = String(text.suffix(120))
                    for sentence in self.segmenter.update(text) { self.emit(sentence) }
                    if result.isFinal { self.endTask() }
                }
                if error != nil { self.endTask() }
            }
        }
    }

    private func endTask() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        generation += 1
        if running { _status = "ses bekleniyor" }
    }

    private func emit(_ sentence: String) {
        _utterances += 1
        onUtterance?(sentence)
    }

    /// Konuşma durunca kalan kısmı verir; uzun süren görevi sessiz bir anda yeniler.
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if let rest = self.segmenter.flushIfSilent() { self.emit(rest) }
            // Görev uzadıkça döküm büyür ve tanıma ağırlaşır: konuşma yokken yenile.
            if self.request != nil, !self.segmenter.hasPending, Date().timeIntervalSince(self.taskStarted) > 25 {
                self.endTask()
            }
        }
        timer.resume()
        self.timer = timer
    }
}
