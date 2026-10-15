import AVFoundation
import AudioToolbox
import Combine
import CoreAudio

/// Live mic-to-output passthrough: when toggled on, captures from the selected (or system
/// default) input device and feeds it straight to the system default output device via a
/// dedicated AVAudioEngine, so whatever's plugged in as the active speaker (built-in, USB,
/// Bluetooth) hears the mic live. Runs alongside, not through, AudioPlayerManager's own engine.
final class MicrophoneManager: ObservableObject {
    @Published private(set) var isLive = false

    /// Rebuilt on every start rather than reused: an engine's output node stays bound to whatever
    /// device was the default when it was first configured, so connecting a Bluetooth speaker
    /// mid-session would otherwise leave the mic playing to the old device (or nowhere).
    private var engine: AVAudioEngine?
    private var volume: Float = 1.0
    private var selectedDeviceUID: String?
    private var cancellables = Set<AnyCancellable>()
    private var configurationObserver: NSObjectProtocol?
    /// Pending debounced restart. Device changes fire several notifications (CoreAudio default-output
    /// listener plus AVAudioEngineConfigurationChange) while formats are still in flux, so restarts
    /// are coalesced and delayed until the hardware settles.
    private var pendingRestart: DispatchWorkItem?
    private var startRetriesRemaining = 0
    private static let restartDelay: TimeInterval = 0.3
    private static let maxStartRetries = 5
    /// Fixed boost applied before the volume slider. Raw mic level at unity gain is far too quiet
    /// next to the sound effects, so 100% on the slider means +8 dB; the peak limiter applying it
    /// catches loud bursts (shouting, mic bumps) instead of letting them clip the speakers.
    private static let boostDecibels: AudioUnitParameterValue = 8
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        // Follow the system output: when speakers/Bluetooth connect or the user picks a new
        // output, re-route the live mic there so the audience keeps hearing it.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.restartIfLive()
        }
        defaultOutputListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, .main, listener
        )
    }

    deinit {
        if let defaultOutputListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, .main, defaultOutputListener
            )
        }
        stop()
    }

    /// Keeps the selected input device and mic volume in sync with the persisted settings,
    /// hot-swapping the device on the fly if the mic is currently live.
    func bind(to settingsStore: SettingsStore) {
        settingsStore.$settings
            .map(\.microphoneDeviceID)
            .removeDuplicates()
            .sink { [weak self] deviceID in
                guard let self else { return }
                selectedDeviceUID = deviceID
                restartIfLive()
            }
            .store(in: &cancellables)

        settingsStore.$settings
            .map(\.microphoneVolume)
            .removeDuplicates()
            .sink { [weak self] volume in
                self?.volume = volume
                self?.engine?.mainMixerNode.outputVolume = volume
            }
            .store(in: &cancellables)
    }

    func toggle() {
        if isLive {
            stop()
        } else {
            start()
        }
    }

    /// Explicit on/off, for push-to-talk (key-down starts it, key-up stops it) as opposed to
    /// `toggle()`'s single key-down flip. Idempotent: calling with the current state is a no-op.
    func setLive(_ shouldBeLive: Bool) {
        if shouldBeLive {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard !isLive else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else { return }
                self?.startEngine()
            }
        }
    }

    private func startEngine() {
        guard !isLive else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = selectedDeviceUID,
           let deviceID = Self.deviceID(forUID: uid),
           let audioUnit = input.audioUnit {
            var device = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        // connect(_:to:format:) raises an uncatchable Objective-C exception if the input format
        // doesn't match the hardware (e.g. mid-switch to a Bluetooth headset's mic profile), so
        // validate first and retry shortly instead of crashing.
        let hardwareFormat = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard hardwareFormat.channelCount > 0, hardwareFormat.sampleRate > 0,
              format.channelCount > 0, format.sampleRate == hardwareFormat.sampleRate
        else {
            retryStartIfNeeded()
            return
        }
        let limiter = Self.makeBoostLimiter()
        engine.attach(limiter)
        engine.connect(input, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume

        engine.prepare()
        guard (try? engine.start()) != nil else {
            retryStartIfNeeded()
            return
        }
        startRetriesRemaining = 0

        // The engine stops itself when its input or output device is reconfigured (e.g. a
        // Bluetooth device connecting, or a sample-rate change); rebuild it so the mic stays live.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartIfLive()
        }
        self.engine = engine
        isLive = true
    }

    private func stop() {
        pendingRestart?.cancel()
        pendingRestart = nil
        startRetriesRemaining = 0
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine?.stop()
        engine = nil
        isLive = false
    }

    private func restartIfLive() {
        guard isLive else { return }
        stop()
        startRetriesRemaining = Self.maxStartRetries
        scheduleStart()
    }

    /// Used when a restart's engine couldn't be started because the device was still reconfiguring.
    /// Only retries restarts; a failed fresh start from the hotkey just leaves the mic off.
    private func retryStartIfNeeded() {
        guard startRetriesRemaining > 0 else { return }
        startRetriesRemaining -= 1
        scheduleStart()
    }

    private func scheduleStart() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRestart = nil
            self?.startEngine()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay, execute: work)
    }

    private static func makeBoostLimiter() -> AVAudioUnitEffect {
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        ))
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, boostDecibels, 0)
        return limiter
    }

    // MARK: - CoreAudio device enumeration

    static func availableInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard inputChannelCount(for: deviceID) > 0,
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID),
                  let name = stringProperty(kAudioDevicePropertyDeviceNameCFString, for: deviceID)
            else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: uid as CFString) { cfUIDPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                cfUIDPointer,
                &dataSize,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer) == noErr else {
            return 0
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr,
              let value
        else {
            return nil
        }
        return value.takeRetainedValue() as String
    }
}
