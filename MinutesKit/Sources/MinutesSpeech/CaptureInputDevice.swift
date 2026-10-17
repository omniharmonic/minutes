import Foundation
import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// A read-only snapshot. Runtime route identifiers stay in memory and are never logged.
public struct CaptureInputDevice: Sendable {
    public let name: String
    public let sampleRate: Double
    public let isBluetooth: Bool
}

public enum CaptureInputDevices {
    public static func current() -> CaptureInputDevice? {
        #if os(macOS)
        guard let device = defaultDevice() else { return nil }
        var name: CFString = "Microphone" as CFString
        guard read(kAudioObjectPropertyName, device: device, value: &name) else { return nil }
        var transport: UInt32 = 0
        var rate: Double = 0
        _ = read(kAudioDevicePropertyTransportType, device: device, value: &transport)
        _ = read(kAudioDevicePropertyNominalSampleRate, device: device, value: &rate)
        return CaptureInputDevice(name: name as String, sampleRate: rate,
            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        #else
        let session = AVAudioSession.sharedInstance()
        guard let input = session.currentRoute.inputs.first else { return nil }
        return CaptureInputDevice(name: input.portName, sampleRate: session.sampleRate,
            isBluetooth: input.portType == .bluetoothHFP || input.portType == .bluetoothLE)
        #endif
    }

    static func routeIdentifiers() -> [String] {
        #if os(macOS)
        return defaultDevice().map { [String($0)] } ?? []
        #else
        return AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid).sorted()
        #endif
    }

    #if os(iOS)
    /// Session-local preference only; never changes the system's global device.
    static func preferredBuiltInMicrophone(in session: AVAudioSession) -> AVAudioSessionPortDescription? {
        session.availableInputs?.first(where: { $0.portType == .builtInMic })
    }
    #endif

    #if os(macOS)
    private static func defaultDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        guard read(kAudioHardwarePropertyDefaultInputDevice, device: AudioObjectID(kAudioObjectSystemObject), value: &device),
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func read<T>(_ selector: AudioObjectPropertySelector, device: AudioObjectID, value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) == noErr
        }
    }
    #endif
}
