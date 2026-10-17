// swift-tools-version: 6.0
import PackageDescription
import Foundation

let cliInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/minutes-cli/Info.plist").path

let appInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/MinutesApp/Info.plist").path

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
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7")],
    targets: [
        .target(
            name: "MinutesCore",
            dependencies: [],
            cSettings: [],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "MinutesSpeech",
            dependencies: ["MinutesCore", .product(name: "FluidAudio", package: "FluidAudio")]
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
            ],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", appInfoPlist], .when(platforms: [.macOS]))]
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
            ],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", cliInfoPlist], .when(platforms: [.macOS]))]
        ),
        // Test targets
        .testTarget(name: "MinutesAppTests", dependencies: ["MinutesApp"]),
        .testTarget(
            name: "MinutesCoreTests",
            dependencies: ["MinutesCore", "MinutesSummarize"]
        ),
        .testTarget(
            name: "MinutesSpeechTests",
            dependencies: ["MinutesSpeech", "MinutesSpeakerID"]
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
