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
    case unavailable = "Not implemented"
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
        #if os(macOS)
        let granted = CGPreflightScreenCaptureAccess()
        DispatchQueue.main.async {
            self.screenStatus = granted ? .granted : .denied
        }
        #else
        DispatchQueue.main.async { self.screenStatus = .unavailable }
        #endif
    }
    
    public func requestScreenCaptureAccess() -> Bool {
        #if os(macOS)
        let granted = CGRequestScreenCaptureAccess()
        DispatchQueue.main.async {
            self.screenStatus = granted ? .granted : .denied
        }
        return granted
        #else
        checkScreenCapture()
        return false
        #endif
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
        #if os(macOS)
        // ScreenCaptureKit uses Screen & System Audio Recording permission.
        // Preflight does not request access or open any capture devices.
        let granted = CGPreflightScreenCaptureAccess()
        DispatchQueue.main.async { self.systemAudioStatus = granted ? .granted : .denied }
        #else
        DispatchQueue.main.async { self.systemAudioStatus = .unavailable }
        #endif
    }
    
    public func requestSystemAudioAccess() async -> Bool {
        #if os(macOS)
        let granted = await MainActor.run { CGRequestScreenCaptureAccess() }
        await MainActor.run {
            self.systemAudioStatus = granted ? .granted : .denied
            self.screenStatus = granted ? .granted : .denied
        }
        return granted
        #else
        checkSystemAudio()
        return false
        #endif
    }
}
