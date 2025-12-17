import AVFoundation

class Metronome {
    private var eventTick: EventTickHandler?
    private var audioPlayerNode: AVAudioPlayerNode = AVAudioPlayerNode()
    private var audioEngine: AVAudioEngine = AVAudioEngine()
    private var mixerNode: AVAudioMixerNode
    private var audioBuffer: AVAudioPCMBuffer?
    //
    private var audioFileMain: AVAudioFile
    private var audioFileAccented: AVAudioFile
    private var audioFilePreCountMain: AVAudioFile
    private var audioFilePreCountAccented: AVAudioFile
    public var audioBpm: Int = 120
    public var audioVolume: Float = 0.5
    public var audioTimeSignature: Int = 0
    
    // プリカウント関連
    private var preCountBarsConfigured: Int = 0
    private var isInPreCount: Bool = false
    private var currentTick: Int = 0
    private var isFirstTick: Bool = false
    private var remainingPreCountBarsToWrite: Int = 0

    private var sampleRate: Int = 44100
    private var timer: DispatchSourceTimer?
    private var startTime: AVAudioTime?
    /// Initialize the metronome with the main and accented audio files.
    init(mainFileBytes: Data, accentedFileBytes: Data, bpm: Int, timeSignature: Int = 0, volume: Float, sampleRate: Int, preCountBars: Int = 0, preCountMainFileBytes: Data = Data(), preCountAccentedFileBytes: Data = Data()) {
        self.sampleRate = sampleRate
        audioTimeSignature = timeSignature
        audioBpm = bpm
        audioVolume = volume
        preCountBarsConfigured = max(0, preCountBars)
        // Initialize audio files
        audioFileMain = try! AVAudioFile(fromData: mainFileBytes)
        if accentedFileBytes.isEmpty {
            audioFileAccented = audioFileMain
        }else{
            audioFileAccented = try! AVAudioFile(fromData: accentedFileBytes)
        }
        // Initialize pre-count audio files
        if preCountMainFileBytes.isEmpty {
            audioFilePreCountMain = audioFileMain
        } else {
            audioFilePreCountMain = try! AVAudioFile(fromData: preCountMainFileBytes)
        }
        if preCountAccentedFileBytes.isEmpty {
            audioFilePreCountAccented = audioFileAccented
        } else {
            audioFilePreCountAccented = try! AVAudioFile(fromData: preCountAccentedFileBytes)
        }
#if os(iOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
            )
            
            try audioSession.setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
#endif
        // Initialize audio engine and player node
        audioEngine.attach(audioPlayerNode)
        // Set up mixer node
        mixerNode = audioEngine.mainMixerNode
        mixerNode.outputVolume = audioVolume
        // Connect nodes
        audioEngine.connect(audioPlayerNode, to: mixerNode, format: audioFileMain.processingFormat)
        audioEngine.prepare()
        // Start the audio engine
        if !self.audioEngine.isRunning {
            do {
                try self.audioEngine.start()
                print("Start the audio engine")
            } catch {
                print("Failed to start audio engine: \(error.localizedDescription)")
            }
        }
        // Set volume
        setVolume(volume:volume)
#if os(iOS)
        setupNotifications()
#endif
    }
    /// Start the metronome.
    func play(preCountBarsOverride: Int = -1) {
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                print("Audio engine failed to start in play(): \(error)")
                return
            }
        }
        
        let bars = (preCountBarsOverride >= 0) ? preCountBarsOverride : preCountBarsConfigured
        isInPreCount = bars > 0
        currentTick = isInPreCount ? -(bars * audioTimeSignature) : 0
        remainingPreCountBarsToWrite = max(0, bars)
        isFirstTick = true
        
        if eventTick != nil {
            eventTick?.send(res: currentTick)
        }
        
        audioBuffer = generateBuffer()
    }

    /// Pause the metronome.
    func pause() {
        stop()
    }
    
    /// Stop the metronome.
    func stop() {
        if audioBuffer != nil {
            audioBuffer?.frameLength = 0
            self.audioPlayerNode.scheduleBuffer(audioBuffer!, at: nil, options: .interruptsAtLoop, completionHandler: nil)
        }
        audioPlayerNode.stop()
        stopBeatTimer()
    }
    
    /// Set the BPM of the metronome.
    func setBPM(bpm: Int) {
        if audioBpm != bpm {
            audioBpm = bpm
            if isPlaying {
                pause()
                play(preCountBarsOverride: 0)
            }
        }
    }
    ///Set the TimeSignature of the metronome.
    func setTimeSignature(timeSignature: Int) {
        if audioTimeSignature != timeSignature {
            audioTimeSignature = timeSignature
            if isPlaying {
                pause()
                play(preCountBarsOverride: 0)
            }
        }
    }
    
    func setAudioFile(mainFileBytes: Data, accentedFileBytes: Data) {
        if !mainFileBytes.isEmpty {
            audioFileMain = try! AVAudioFile(fromData: mainFileBytes)
        }
        if !accentedFileBytes.isEmpty {
            audioFileAccented = try! AVAudioFile(fromData: accentedFileBytes)
        }
        if !mainFileBytes.isEmpty || !accentedFileBytes.isEmpty {
            if isPlaying {
                pause()
                play(preCountBarsOverride: 0)
            }
        }
    }
    
    var getTimeSignature: Int {
        return audioTimeSignature
    }
    
    var getVolume: Int {
        return Int(audioVolume * 100)
    }
    
    func setVolume(volume: Float) {
        audioVolume = volume
        mixerNode.outputVolume = volume
    }
    
    var isPlaying: Bool {
        return audioPlayerNode.isPlaying
    }
    
    /// Enable the tick callback.
    public func enableTickCallback(_eventTickSink: EventTickHandler) {
        self.eventTick = _eventTickSink
    }
#if os(iOS)
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main,
            using: handleInterruption
        )
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main,
            using: handleRouteChange
        )
    }

    private func handleInterruption(_ notification: Notification) {
        if isPlaying {
            pause()
        }
    }
    private func handleRouteChange(_ notification: Notification) {
        // let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        // let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue ?? 0)
        // print("Audio route changed. Reason: \(String(describing: reason))")
        let wasPlaying = isPlaying
        if wasPlaying {
            pause()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            do {
                // let session = AVAudioSession.sharedInstance()
                // let outputs = session.currentRoute.outputs
                // print("Current audio outputs: \(outputs.map { $0.portType.rawValue })")
                self.audioPlayerNode.stop()
                self.audioEngine.stop()
                self.audioEngine.reset()

                do {
                    try self.audioEngine.start()
                } catch {
                    print("Audio engine failed to restart: \(error.localizedDescription)")
                }

                if wasPlaying {
                    self.play()
                }
            } catch {
                print("Failed to handle audio route change: \(error.localizedDescription)")
            }
        }
    }
#endif
    /// Generate buffer with accents based on time signature
    private func generateBuffer() -> AVAudioPCMBuffer {
        // Decide whether this bar should use pre-count sounds
        let usePrecount = remainingPreCountBarsToWrite > 0
        
        let mainFile = usePrecount ? audioFilePreCountMain : audioFileMain
        let accentedFile = usePrecount ? audioFilePreCountAccented : audioFileAccented
        
        mainFile.framePosition = 0
        accentedFile.framePosition = 0

        let beatLength = AVAudioFrameCount(Double(self.sampleRate) * 60 / Double(self.audioBpm))
        // let beatLength = AVAudioFrameCount(audioFileMain.processingFormat.sampleRate * 60 / Double(self.audioBpm))
        let bufferMainClick = AVAudioPCMBuffer(pcmFormat: mainFile.processingFormat, frameCapacity: beatLength)!
        try! mainFile.read(into: bufferMainClick)
        bufferMainClick.frameLength = beatLength

        let bufferBar: AVAudioPCMBuffer
        if self.audioTimeSignature < 2 {
            bufferBar = AVAudioPCMBuffer(pcmFormat: mainFile.processingFormat, frameCapacity: beatLength)!
            bufferBar.frameLength = beatLength

            let channelCount = Int(mainFile.processingFormat.channelCount)
            let mainClickArray = Array(UnsafeBufferPointer(start: bufferMainClick.floatChannelData![0], count: channelCount * Int(beatLength)))

            bufferBar.floatChannelData!.pointee.update(from: mainClickArray, count: channelCount * Int(bufferBar.frameLength))
        } else {
            let bufferAccentedClick = AVAudioPCMBuffer(pcmFormat: accentedFile.processingFormat, frameCapacity: beatLength)!
            try! accentedFile.read(into: bufferAccentedClick)
            bufferAccentedClick.frameLength = beatLength

            bufferBar = AVAudioPCMBuffer(pcmFormat: mainFile.processingFormat, frameCapacity: beatLength * AVAudioFrameCount(self.audioTimeSignature))!
            bufferBar.frameLength = beatLength * AVAudioFrameCount(self.audioTimeSignature)

            let channelCount = Int(mainFile.processingFormat.channelCount)
            let mainClickArray = Array(UnsafeBufferPointer(start: bufferMainClick.floatChannelData![0], count: channelCount * Int(beatLength)))
            let accentedClickArray = Array(UnsafeBufferPointer(start: bufferAccentedClick.floatChannelData![0], count: channelCount * Int(beatLength)))

            var barArray = [Float]()
            for i in 0..<self.audioTimeSignature {
                if i == 0 {
                    barArray.append(contentsOf: accentedClickArray)
                } else {
                    barArray.append(contentsOf: mainClickArray)
                }
            }

            bufferBar.floatChannelData!.pointee.update(from: barArray, count: channelCount * Int(bufferBar.frameLength))
        }
        
        // Consume one scheduled pre-count bar if used
        if usePrecount && remainingPreCountBarsToWrite > 0 {
            remainingPreCountBarsToWrite -= 1
        }
        
        //
        self.startTime = self.audioPlayerNode.lastRenderTime
        self.audioPlayerNode.scheduleBuffer(bufferBar, at: nil, options: .loops,completionHandler: nil)
        self.audioPlayerNode.play()
        startBeatTimer()
        return bufferBar
    }
    
    func stopBeatTimer() {
        if timer != nil {
            timer?.cancel()
            timer = nil
        }
    }
    
    private func startBeatTimer() {
        if self.eventTick == nil {return}
        let beatDuration = 60.0 / Double(audioBpm)
        timer?.cancel()
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        timer?.schedule(deadline: .now(), repeating: beatDuration, leeway: .milliseconds(10))
        timer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            if self.isFirstTick {
                self.isFirstTick = false
                return
            }
            
            if self.isInPreCount {
                self.currentTick += 1
                if self.currentTick == 0 {
                    self.isInPreCount = false
                }
                DispatchQueue.main.async {
                    self.eventTick?.send(res: self.currentTick)
                }
            } else {
                guard let startTime = self.startTime,
                      let currentTime = self.audioPlayerNode.lastRenderTime,
                      let elapsedTime = self.getElapsedTime(from: startTime, to: currentTime) else { return }

                let currentBeat = Int(elapsedTime / beatDuration)
                let currentTickValue = (self.audioTimeSignature > 1) ? (currentBeat % self.audioTimeSignature) : 0

                DispatchQueue.main.async {
                    self.eventTick?.send(res: currentTickValue)
                }
            }
        }

        timer?.resume()
    }
    
    private func getElapsedTime(from startTime: AVAudioTime, to currentTime: AVAudioTime) -> TimeInterval? {
//        guard let sampleRate = startTime.sampleRate as Double? else { return nil }
        let elapsedSamples = currentTime.sampleTime - startTime.sampleTime
        return Double(elapsedSamples) / Double(self.sampleRate)
    }

    func destroy() {
        audioPlayerNode.reset()
        audioPlayerNode.stop()
        audioEngine.reset()
        audioEngine.stop()
        audioEngine.detach(audioPlayerNode)
        audioBuffer = nil
        stopBeatTimer()
    }
}
extension AVAudioFile {
    convenience init(fromData data: Data) throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".wav")
        do {
            try data.write(to: tempURL)
            //print("Temporary file created at: \(tempURL)")
        } catch {
            //print("Failed to write data to temporary file: \(error.localizedDescription)")
            throw error
        }
        do {
            try self.init(forReading: tempURL)
        } catch {
            //print("Failed to initialize AVAudioFile: \(error.localizedDescription)")
            throw error
        }
    }
}
