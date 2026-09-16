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

    private let engine = AVAudioEngine()
    private var selectedDeviceUID: String?
    private var cancellables = Set<AnyCancellable>()

    /// Keeps the selected input device in sync with the persisted settings, hot-swapping the
    /// device on the fly if the mic is currently live.
    func bind(to settingsStore: SettingsStore) {
        settingsStore.$settings
            .map(\.microphoneDeviceID)
            .removeDuplicates()
            .sink { [weak self] deviceID in
                guard let self else { return }
                selectedDeviceUID = deviceID
                if isLive {
                    stop()
                    start()
                }
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

        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        engine.connect(input, to: engine.mainMixerNode, format: format)

        engine.prepare()
        isLive = (try? engine.start()) != nil
    }

    private func stop() {
        engine.stop()
        engine.disconnectNodeInput(engine.mainMixerNode)
        isLive = false
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
