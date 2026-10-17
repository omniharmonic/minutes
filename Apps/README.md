# Native iOS application

Build with Xcode 26 or newer for the Liquid Glass and Foundation Models SDK symbols; deployment remains iOS 18+.

`project.yml` is the source of truth. `Minutes.xcodeproj` and the target Info.plist are generated with [XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0). Do not edit the project file directly.

Use the official `xcodegen.zip` release archive. Its SHA256 is `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`. An extracted executable can stay in a temporary directory; no global installation is required:

```sh
XCODEGEN_BIN=/path/to/xcodegen/bin/xcodegen ./Apps/generate-project.sh
xcodebuild -project Apps/Minutes.xcodeproj -scheme MinutesiOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/minutes-ios-build CODE_SIGNING_ALLOWED=NO build
```

Open `Minutes.xcodeproj` to select a Simulator or configure your own signing team for a physical device. The deployment target is iOS 18. The shared Swift package pins FluidAudio 0.17.7 and includes its SDK resources through SwiftPM.

The app uses the shared AppState, store, calendar provider, capture service, and speech pipeline. It provides a meeting library, audio and untimed text import, calendar binding, microphone recording, stop-and-process, saved-audio retry, transcript editing, speaker confirmation, optional local voice learning, and voiceprint deletion. Model setup is an explicit Settings action. A missing model or unavailable on-device recognizer preserves saved audio and reports the problem.

The Simulator build proves compilation and linking. An isolated iPhone 17 Pro / iOS 27 Simulator startup smoke also rendered the library with the process alive and no permission prompts; its temporary device was then deleted. No microphone or calendar/model setup action was invoked. Physical-device microphone permissions, background recording, interruptions, performance, and App Store distribution require separate validation. The build command itself does not launch the app.
