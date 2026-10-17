import Foundation
import Testing
@testable import MinutesApp

@MainActor struct IsolatedLibraryTests {
    @Test("An explicit library directory uses its own database and preserves failure visibility")
    func isolatedLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let startup = AppStartup(libraryDirectory: root)
        #expect(startup.state != nil)
        #expect(startup.state?.markdownDirectory == root.appendingPathComponent("exports").path)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("minutes.sqlite").path))
        let blocked = root.appendingPathComponent("not-a-folder")
        try Data([0]).write(to: blocked)
        let failed = AppStartup(libraryDirectory: blocked)
        #expect(failed.state == nil)
        #expect(failed.errorMessage != nil)
    }
}
