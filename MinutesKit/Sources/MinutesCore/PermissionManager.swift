import Foundation
import Combine
import AVFoundation
import EventKit
import CoreGraphics

public enum PermissionStatus: String, Sendable, CaseIterable {
    case granted = "Granted"
    case denied = "Denied"
    case notDetermined = "Not Determined"
    case restricted = "Restricted"
}

public final class PermissionManager: ObservableObject, @unchecked Sendable {
    public static let shared = PermissionManager()
    
    @Published public private(set) var micStatus: PermissionStatus = .notDetermined
    @Published public private(set) var systemAudioStatus: PermissionStatus = .notDetermined
    @Published public private(set) var screenStatus: PermissionStatus = .notDetermined
    @Published public private(set) var calendarStatus: PermissionStatus = .notDetermined
    
    private let eventStore = EKEventStore()
    private let lock = NSLock()
    
    public init() {
        checkAllPermissions()
    }
    
    public func checkAllPermissions() {
        checkMicrophone()
        checkSystemAudio()
        checkScreenCapture()
        checkCalendar()
    }
    
    public func checkMicrophone() {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        let status: PermissionStatus
        switch auth {
        case .authorized:
            status = .granted
        case .denied:
            status = .denied
        case .restricted:
            status = .restricted
        case .notDetermined:
            status = .notDetermined
        @unknown default:
            status = .notDetermined
        }
        
        DispatchQueue.main.async {
            self.micStatus = status
        }
    }
    
    public func requestMicrophoneAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
            self.micStatus = granted ? .granted : .denied
        }
        return granted
    }
    
    public func checkScreenCapture() {
        let granted = CGPreflightScreenCaptureAccess()
        DispatchQueue.main.async {
            self.screenStatus = granted ? .granted : .denied
        }
    }
    
    public func requestScreenCaptureAccess() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        DispatchQueue.main.async {
            self.screenStatus = granted ? .granted : .denied
        }
        return granted
    }
    
    public func checkCalendar() {
        let auth = EKEventStore.authorizationStatus(for: .event)
        let status: PermissionStatus
        switch auth {
        case .authorized, .fullAccess:
            status = .granted
        case .denied:
            status = .denied
        case .restricted:
            status = .restricted
        case .notDetermined, .writeOnly:
            status = .notDetermined
        @unknown default:
            status = .notDetermined
        }
        
        DispatchQueue.main.async {
            self.calendarStatus = status
        }
    }
    
    public func requestCalendarAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                let granted = try await eventStore.requestFullAccessToEvents()
                await MainActor.run {
                    self.calendarStatus = granted ? .granted : .denied
                }
                return granted
            } else {
                let granted = try await eventStore.requestAccess(to: .event)
                await MainActor.run {
                    self.calendarStatus = granted ? .granted : .denied
                }
                return granted
            }
        } catch {
            await MainActor.run {
                self.calendarStatus = .denied
            }
            return false
        }
    }
    
    public func checkSystemAudio() {
        // Core Audio Process Tap (CATap) status on macOS 14.2+
        // In local non-sandboxed CLI/app environment, system audio taps inherit microphone / screen capture entitlements.
        // We verify that input audio hardware / tap capability is present.
        let hasAudioDevice = !AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.isEmpty
        
        DispatchQueue.main.async {
            self.systemAudioStatus = hasAudioDevice ? .granted : .notDetermined
        }
    }
    
    public func requestSystemAudioAccess() async -> Bool {
        checkSystemAudio()
        return systemAudioStatus == .granted
    }
}
