#if os(macOS) && canImport(SwiftUI)
import Foundation
import MinutesCore
import MinutesSpeech
import MinutesSpeakerID
import MinutesCalendar
import MinutesExport
import MinutesControl

/// The control-socket API (docs/CONTROL_API.md). Every method runs on the main
/// actor against the same AppState the window uses. Unlike the Record button,
/// an API start never falls back to another capture source.
extension AppState {
    public func handleControlRequest(_ request: ControlRequest) async -> ControlResponse {
        do {
            guard let method = ControlMethod(rawValue: request.method) else {
                throw ControlError(.unknownMethod, "Unknown method \"\(request.method)\"")
            }
            let result: JSONValue
            switch method {
            case .status: result = controlStatus()
            case .start: result = try await controlStart(ControlStartParams(params: request.params))
            case .stop: result = try await controlStop(ControlMeetingParams(params: request.params))
            case .mark: result = try controlMark(ControlMarkParams(params: request.params))
            case .get: result = try controlGet(ControlMeetingParams(params: request.params))
            case .assign: result = try controlAssign(ControlAssignParams(params: request.params))
            case .export: result = try await controlExport(ControlMeetingParams(params: request.params))
            }
            return ControlResponse(id: request.id, result: result)
        } catch let error as ControlError {
            return ControlResponse(id: request.id, error: error)
        } catch {
            return ControlResponse(id: request.id, error: ControlError(.internal, error.localizedDescription))
        }
    }

    // MARK: status

    var controlNotReadyReason: String? {
        refreshSpeechReadiness()
        if !recordingConsentAcknowledged {
            return "Recording consent has not been acknowledged in Minutes (finish the welcome screen, or defaults write ai.nosaas.minutes recordingConsentAcknowledged -bool true)."
        }
        if isSettingUpSpeechModels { return "Speaker models are being installed." }
        if !recordingModelsReady { return speechModelStatus }
        return nil
    }

    static func controlName(_ mode: CaptureMode?) -> JSONValue {
        switch mode {
        case .microphone?: "microphone"
        case .systemAudio?: "system_audio"
        case .systemAndMicrophone?: "system_and_microphone"
        case nil: nil
        }
    }

    func controlStatus() -> JSONValue {
        let reason = controlNotReadyReason
        let devices = CaptureInputDevices.defaultDeviceNames()
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "unknown") (\(info["CFBundleVersion"] as? String ?? "unknown"))"
        return [
            "recording": .bool(isRecording),
            "meeting_id": .optional(isRecording ? activeRecordingMeetingID : nil),
            "capture_mode": Self.controlName(recordingCaptureMode),
            "duration_s": .number(isRecording ? recordingMeter.duration : 0),
            "processing": .bool(isProcessing || isFinalizingRecording),
            "starting": .bool(isStartingRecording || isPreparingRecording),
            "ready": .bool(reason == nil),
            "not_ready_reason": .optional(reason),
            "system_audio_permission": .bool(systemCapturePreflight()),
            "default_output_device": .optional(devices.output),
            "default_input_device": .optional(devices.input),
            "version": .string(version)
        ]
    }

    // MARK: start / stop / mark

    private var controlBusyReason: String? {
        if isRecording { return "A recording is already running (\(activeRecordingMeetingID ?? "unknown"))." }
        if isStartingRecording || isPreparingRecording { return "A recording is starting." }
        if isFinalizingRecording || isProcessing { return "The previous recording is still being finalized or processed." }
        return nil
    }

    func controlStart(_ params: ControlStartParams) async throws -> JSONValue {
        if let busy = controlBusyReason { throw ControlError(.busy, busy) }
        if let reason = controlNotReadyReason { throw ControlError(.notReady, reason) }
        let mode: CaptureMode = params.captureMode == .systemAndMicrophone ? .systemAndMicrophone : .systemAudio
        // The Record button drops to microphone-only here; the API never does.
        guard systemCapturePreflight() else {
            throw ControlError(.permissionDenied, "Screen & System Audio Recording is not allowed for Minutes. Allow it in System Settings > Privacy & Security > Screen & System Audio Recording.")
        }
        if mode.includesMicrophone && !microphoneAuthorized() {
            throw ControlError(.permissionDenied, "Microphone access is not allowed for Minutes. Allow it in System Settings > Privacy & Security > Microphone, or use capture_mode system_audio.")
        }
        isPreparingRecording = true
        do {
            if let recordingEnvironmentPreflight { try await recordingEnvironmentPreflight() }
            else {
                try ModelManager.shared.validateDiarizationModels()
                try await ASRService().prepareForRecording()
            }
        } catch {
            isPreparingRecording = false
            throw ControlError(.notReady, "Recording setup: \(error.localizedDescription)")
        }
        isPreparingRecording = false
        // Someone may have pressed Record while the setup check ran.
        if let busy = controlBusyReason { throw ControlError(.busy, busy) }

        let event = controlEvent(for: params)
        activeCaptureMode = mode
        do {
            let id = try await beginSystemMeeting(event: event, includeMicrophone: mode.includesMicrophone, title: params.title,
                                                  replacesCalendarEventID: true, calendarEventID: params.eventID)
            return ["meeting_id": .string(id), "capture_mode": Self.controlName(recordingCaptureMode ?? mode)]
        } catch let error as RecordingStartError {
            activeCaptureMode = nil
            switch error {
            case .busy: throw ControlError(.busy, controlBusyReason ?? "Minutes is busy.")
            case .notReady: throw ControlError(.notReady, controlNotReadyReason ?? speechModelStatus)
            case .failed(let underlying): throw ControlError(.internal, "System recording failed: \(underlying.localizedDescription)")
            }
        }
    }

    /// The calendar event the meeting is bound to: a loaded event with this id
    /// when there is one (so its prompt is dismissed), otherwise one built from
    /// the request so attendees are stored the same way. Nil without either.
    private func controlEvent(for params: ControlStartParams) -> CalendarMeetingEvent? {
        if let eventID = params.eventID,
           let known = upcomingEvents.first(where: { $0.id == eventID || $0.eventIdentifier == eventID }), !known.isCancelled {
            return known
        }
        guard params.eventID != nil || !params.attendees.isEmpty else { return nil }
        let attendees = params.attendees.map { attendee -> CalendarMeetingAttendee in
            let email = attendee.email.map(NameResolver.cleanEmail).flatMap { $0.contains("@") ? $0 : nil }
            return CalendarMeetingAttendee(displayName: attendee.name ?? email.map(NameResolver.resolveDisplayName) ?? "Unknown invitee",
                email: email, isCurrentUser: false, isOrganizer: false, responseStatus: "unknown")
        }
        let now = Date()
        return CalendarMeetingEvent(eventIdentifier: params.eventID ?? "control-\(UUID().uuidString)", calendarIdentifier: "control-api",
            title: params.title, start: now, end: now.addingTimeInterval(3600), attendees: attendees)
    }

    func controlStop(_ params: ControlMeetingParams) async throws -> JSONValue {
        guard isRecording, !isFinalizingRecording, let active = activeRecordingMeetingID else {
            throw ControlError(.notRecording, isFinalizingRecording ? "The recording is already stopping." : "Nothing is recording.")
        }
        guard active == params.meetingID else {
            throw ControlError(.wrongMeeting, "Meeting \(active) is recording, not \(params.meetingID).")
        }
        // Processing runs inside stopAndProcessMeeting; answer once capture is finalized.
        Task { await stopAndProcessMeeting() }
        repeat { try? await Task.sleep(for: .milliseconds(50)) } while isRecording || isFinalizingRecording
        if store.getMeeting(id: active)?.status == "failed" {
            throw ControlError(.internal, statusMessage)
        }
        return ["meeting_id": .string(active), "processing": true]
    }

    func controlMark(_ params: ControlMarkParams) throws -> JSONValue {
        guard isRecording else { throw ControlError(.notRecording, "Nothing is recording.") }
        guard let bookmark = markRecordingMoment(label: params.label ?? "Key moment") else {
            throw ControlError(.internal, statusMessage)
        }
        return ["bookmark_id": .string(bookmark.id), "timestamp_s": .number(bookmark.timestamp), "label": .string(bookmark.label)]
    }

    // MARK: get / assign / export

    static func controlJSON(_ cluster: SpeakerCluster) -> JSONValue {
        ["id": .string(cluster.id), "track_id": .string(cluster.trackId), "label": .string(cluster.label),
         "speech_seconds": .number(cluster.speechSeconds), "assignment": .string(cluster.assignment),
         "person_id": .optional(cluster.personId), "confidence": .number(cluster.confidence)]
    }

    func controlGet(_ params: ControlMeetingParams) throws -> JSONValue {
        guard let meeting = store.getMeeting(id: params.meetingID) else { throw ControlError(.notFound, "Meeting \(params.meetingID) was not found.") }
        let clusters = store.listSpeakerClusters(meetingId: meeting.id)
        let utterances = TranscriptSpeakerLabels.readableUtterances(store.listUtterances(meetingId: meeting.id), clusters: clusters)
        return [
            "meeting": ["id": .string(meeting.id), "title": .string(meeting.title), "status": .string(meeting.status),
                        "started_at": .number(meeting.startedAt.timeIntervalSince1970),
                        "ended_at": .optional(meeting.endedAt?.timeIntervalSince1970),
                        "calendar_event_id": .optional(meeting.calendarEventId)],
            "clusters": .array(clusters.map(Self.controlJSON)),
            "utterances": .array(utterances.map {
                ["id": .number(Double($0.id)), "cluster_id": .string($0.clusterId), "speaker_name": .string($0.speakerName),
                 "start": .number($0.start), "end": .number($0.end), "text": .string($0.text)]
            })
        ]
    }

    func controlAssign(_ params: ControlAssignParams) throws -> JSONValue {
        guard let meeting = store.getMeeting(id: params.meetingID) else { throw ControlError(.notFound, "Meeting \(params.meetingID) was not found.") }
        // The pipeline rewrites clusters when it finishes; a name given now would be lost.
        guard !["starting", "recording", "processing"].contains(meeting.status) else {
            throw ControlError(.busy, "Meeting \(meeting.id) is \(meeting.status); assign speakers after processing finishes.")
        }
        do {
            let outcome = try assignSpeaker(meetingID: meeting.id, clusterID: params.clusterID, name: params.name, email: params.email, learn: params.learn)
            return ["cluster": Self.controlJSON(outcome.cluster), "person_id": .string(outcome.person.id), "learned": .bool(outcome.voiceprint != nil)]
        } catch let error as SpeakerAssignmentError {
            switch error {
            case .meetingNotFound, .clusterNotFound, .utteranceNotFound: throw ControlError(.notFound, error.localizedDescription)
            case .emptyName, .cannotLearn: throw ControlError(.badRequest, error.localizedDescription)
            }
        } catch let error as VoiceEnrollmentError {
            throw ControlError(.badRequest, error.localizedDescription)
        }
    }

    func controlExport(_ params: ControlMeetingParams) async throws -> JSONValue {
        guard store.getMeeting(id: params.meetingID) != nil else { throw ControlError(.notFound, "Meeting \(params.meetingID) was not found.") }
        guard parachuteVault != nil else {
            return ["exported": false, "path": nil, "reason": "No Parachute vault is connected in Minutes Settings."]
        }
        do {
            let result = try await saveToParachuteVault(meetingID: params.meetingID)
            return ["exported": .bool(result.success), "path": .optional(result.pathOrURL), "note_id": .optional(result.externalRef)]
        } catch ParachuteVaultError.editedInVault {
            return ["exported": false, "path": nil, "reason": .optional(ParachuteVaultError.editedInVault.errorDescription)]
        } catch {
            throw ControlError(.internal, "Vault export failed: \(error.localizedDescription)")
        }
    }
}
#endif
