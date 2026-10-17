import Foundation
import Speech
import CryptoKit
import FluidAudio
import MinutesCore

public struct SpeechModelInfo: Sendable, Codable {
    public let id: String
    public let name: String
    public let version: String
    public let sizeBytes: Int64
    public let sha256: String
    public let supportsANE: Bool
    public let isOfflineReady: Bool
    
    public init(
        id: String,
        name: String,
        version: String,
        sizeBytes: Int64,
        sha256: String,
        supportsANE: Bool,
        isOfflineReady: Bool
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.supportsANE = supportsANE
        self.isOfflineReady = isOfflineReady
    }
}

public enum ModelDownloadState: Sendable {
    case ready
    case downloading(progress: Double)
    case failed(error: String)
    case notDownloaded
}

public final class ModelManager: Sendable {
    public static let shared = ModelManager()
    public let modelsDirectory: URL

    public init(modelsDirectory: URL? = nil) {
        // The SDK derives the repository folder from its parent directory.
        // Keep this fixed leaf even when callers select an isolated cache root.
        let root = modelsDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Minutes/Models", isDirectory: true)
        self.modelsDirectory = root.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    public var segmentationModelURL: URL { modelsDirectory.appendingPathComponent("pyannote_segmentation.mlmodelc") }
    public var embeddingModelURL: URL { modelsDirectory.appendingPathComponent("wespeaker_v2.mlmodelc") }
    private var manifestURL: URL { modelsDirectory.appendingPathComponent("minutes-model-integrity.json") }

    private struct Installation: Codable {
        let model: String
        let hashes: [String: String]
        let byteCount: Int64
    }

    /// Only this explicit setup operation invokes the SDK's model downloader.
    /// Processing uses local URLs and never calls a downloader or auto-recovery.
    public func setupDiarizationModels() async throws {
        try await SpeakerModelSetupCoordinator.shared.install(self)
    }

    fileprivate func installDiarizationModels() async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        _ = try await DiarizerModels.downloadIfNeeded(to: modelsDirectory)
        let files = try inventory()
        let installation = Installation(model: SpeakerEmbeddingModel.trainedID,
                                        hashes: files.hashes, byteCount: files.byteCount)
        try JSONEncoder().encode(installation).write(to: manifestURL, options: .atomic)
    }

    public func diarizationReadiness() -> (ready: Bool, reason: String) {
        guard let data = try? Data(contentsOf: manifestURL),
              let installation = try? JSONDecoder().decode(Installation.self, from: data),
              installation.model == SpeakerEmbeddingModel.trainedID,
              !installation.hashes.isEmpty else {
            return (false, "Download speaker recognition to identify voices on this Mac.")
        }
        for bundle in [segmentationModelURL, embeddingModelURL] {
            let coreData = bundle.appendingPathComponent("coremldata.bin")
            guard FileManager.default.fileExists(atPath: coreData.path) else {
                return (false, "Speaker model files are incomplete. Run speaker model setup again.")
            }
        }
        return (true, "Speaker recognition is ready.")
    }

    /// Validate the bytes that explicit setup installed before Core ML can read
    /// them. A corrupt model fails locally; there is no automatic redownload.
    public func validateDiarizationModels() throws {
        guard diarizationReadiness().ready else { throw SpeechModelsError.missingDiarizationModels }
        let installation = try JSONDecoder().decode(Installation.self, from: Data(contentsOf: manifestURL))
        let files = try inventory()
        guard installation.hashes == files.hashes else { throw SpeechModelsError.missingDiarizationModels }
    }

    private func inventory() throws -> (hashes: [String: String], byteCount: Int64) {
        var hashes: [String: String] = [:]
        var byteCount: Int64 = 0
        for bundle in [segmentationModelURL, embeddingModelURL] {
            guard let enumerator = FileManager.default.enumerator(at: bundle,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                throw SpeechModelsError.missingDiarizationModels
            }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw SpeechModelsError.missingDiarizationModels }
                guard values.isRegularFile == true else { continue }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                let relative = file.resolvingSymlinksInPath().pathComponents.dropFirst(modelsDirectory.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
                hashes[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                byteCount += Int64(data.count)
            }
        }
        guard hashes.keys.contains(where: { $0.hasPrefix("pyannote_segmentation.mlmodelc/") }),
              hashes.keys.contains(where: { $0.hasPrefix("wespeaker_v2.mlmodelc/") }) else {
            throw SpeechModelsError.missingDiarizationModels
        }
        return (hashes, byteCount)
    }

    public func getInstalledModels() -> [SpeechModelInfo] {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        let appleReady = recognizer?.supportsOnDeviceRecognition == true &&
            recognizer?.isAvailable == true && SFSpeechRecognizer.authorizationStatus() == .authorized
        let installed = (try? Data(contentsOf: manifestURL)).flatMap {
            try? JSONDecoder().decode(Installation.self, from: $0)
        }
        return [
            SpeechModelInfo(id: "apple_speech_en_us", name: "Apple on-device speech",
                            version: "System managed", sizeBytes: 0, sha256: "",
                            supportsANE: false, isOfflineReady: appleReady),
            SpeechModelInfo(id: SpeakerEmbeddingModel.trainedID,
                            name: "Pyannote + WeSpeaker speaker diarization",
                            version: "FluidAudio 0.17.7", sizeBytes: installed?.byteCount ?? 0,
                            sha256: "", supportsANE: true,
                            isOfflineReady: diarizationReadiness().ready)
        ]
    }

    public func checkReadiness() -> (ready: Bool, reason: String) {
        let diarization = diarizationReadiness()
        guard diarization.ready else { return diarization }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return (false, "Speech recognition permission is required for Apple on-device transcription.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            return (false, "On-device English speech recognition is unavailable on this device.")
        }
        return (true, "Speaker model files installed and Apple on-device recognition available.")
    }
}

private actor SpeakerModelSetupCoordinator {
    static let shared = SpeakerModelSetupCoordinator()
    private var pending: [URL: Task<Void, Error>] = [:]

    func install(_ manager: ModelManager) async throws {
        let path = manager.modelsDirectory.standardizedFileURL
        if let task = pending[path] { return try await task.value }
        let task = Task { try await manager.installDiarizationModels() }
        pending[path] = task
        defer { pending[path] = nil }
        try await task.value
    }
}
