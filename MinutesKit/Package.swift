// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MinutesKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "MinutesCore", targets: ["MinutesCore"]),
        .library(name: "MinutesSpeech", targets: ["MinutesSpeech"]),
        .library(name: "MinutesSpeakerID", targets: ["MinutesSpeakerID"]),
        .library(name: "MinutesCalendar", targets: ["MinutesCalendar"]),
        .library(name: "MinutesSummarize", targets: ["MinutesSummarize"]),
        .library(name: "MinutesExport", targets: ["MinutesExport"]),
        .library(name: "MinutesUI", targets: ["MinutesUI"]),
        .executable(name: "MinutesApp", targets: ["MinutesApp"]),
        .executable(name: "minutes-cli", targets: ["minutes-cli"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MinutesCore",
            dependencies: [],
            cSettings: [],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "MinutesSpeech",
            dependencies: ["MinutesCore"]
        ),
        .target(
            name: "MinutesSpeakerID",
            dependencies: ["MinutesCore"]
        ),
        .target(
            name: "MinutesCalendar",
            dependencies: ["MinutesCore"]
        ),
        .target(
            name: "MinutesSummarize",
            dependencies: ["MinutesCore"]
        ),
        .target(
            name: "MinutesExport",
            dependencies: ["MinutesCore"]
        ),
        .target(
            name: "MinutesUI",
            dependencies: [
                "MinutesCore",
                "MinutesSpeakerID",
                "MinutesSpeech",
                "MinutesCalendar",
                "MinutesSummarize",
                "MinutesExport"
            ]
        ),
        .executableTarget(
            name: "MinutesApp",
            dependencies: [
                "MinutesCore",
                "MinutesSpeech",
                "MinutesSpeakerID",
                "MinutesCalendar",
                "MinutesSummarize",
                "MinutesExport",
                "MinutesUI"
            ]
        ),
        .executableTarget(
            name: "minutes-cli",
            dependencies: [
                "MinutesCore",
                "MinutesSpeech",
                "MinutesSpeakerID",
                "MinutesCalendar",
                "MinutesSummarize",
                "MinutesExport"
            ]
        ),
        // Test targets
        .testTarget(
            name: "MinutesCoreTests",
            dependencies: ["MinutesCore"]
        ),
        .testTarget(
            name: "MinutesSpeechTests",
            dependencies: ["MinutesSpeech"]
        ),
        .testTarget(
            name: "MinutesSpeakerIDTests",
            dependencies: ["MinutesSpeakerID"]
        ),
        .testTarget(
            name: "MinutesCalendarTests",
            dependencies: ["MinutesCalendar", "MinutesSpeakerID"]
        ),
        .testTarget(
            name: "MinutesExportTests",
            dependencies: ["MinutesExport"]
        ),
        .testTarget(
            name: "MinutesSummarizeTests",
            dependencies: ["MinutesSummarize"]
        )
    ]
)
