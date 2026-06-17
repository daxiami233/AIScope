# AIScope

AIScope is a macOS menu bar app for monitoring AI coding-tool quota and usage across local accounts.

It reads supported tools' local auth state, fetches usage from their own APIs, and shows a compact quota dashboard in the menu bar. Credentials stay on the local machine and are stored in macOS Keychain or the original tool configuration files.

## Supported Providers

- Cursor
- Claude Code
- GitHub Copilot
- OpenAI Codex
- Mimocode
- Qoder
- Z.ai / ZCode GLM

## Requirements

- macOS 14.0 or later
- Xcode 16 or later
- Swift 6

## Project Structure

```text
.
├── AIScope/
│   ├── App/                        # App entry and AppKit bridge
│   ├── Assets.xcassets/            # App and provider icons
│   ├── Models/                     # Shared data models and settings
│   ├── Providers/                  # Per-tool quota providers
│   ├── Resources/                  # Info.plist and entitlements
│   ├── Services/                   # Keychain, SQLite, data refresh
│   └── Views/                      # SwiftUI UI
├── AIScope.xcodeproj/              # Xcode project
├── LICENSE
├── project.yml                     # XcodeGen project definition
└── README.md
```

## Build

Open `AIScope.xcodeproj` in Xcode and run the `AIScope` scheme.

Command-line build:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project AIScope.xcodeproj \
  -scheme AIScope \
  -configuration Debug \
  -derivedDataPath /tmp/AIScopeDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Privacy

AIScope does not run a backend service. Provider credentials are read from local files or macOS Keychain, and unified app credentials are stored in the `AIScope.Credentials` Keychain item.

Quota requests are sent directly from the app to each provider's official or local-compatible endpoint.

## Development Notes

- Add new providers under `AIScope/Providers/`.
- Register providers in `DataManager.allProviders`.
- Keep provider IDs stable; they are used for settings, cache, and display order.
- Keep personal Xcode state out of commits. The root `.gitignore` excludes `xcuserdata` and `*.xcuserstate`.
