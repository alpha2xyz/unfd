# AutoLang

Switches the keyboard language by itself: English in address bars, the chat's language in WhatsApp and other apps.

This file is public-safe: it holds only facts a contributor needs to build and change the app. Private notes live in the workspace folder above this repo, never in this repo.

## Stack

- macOS 14.0+, SwiftUI, Swift 6.0.
- The Xcode project is generated from `project.yml` by XcodeGen. Never edit `AutoLang.xcodeproj` by hand; it is gitignored. Change `project.yml`, then run `xcodegen generate`.

## Layout

- `AutoLang/App/`: app entry point (`@main`) and app-wide settings.
- `AutoLang/Features/<Feature>/`: one folder per screen or feature (view + its logic).
- `AutoLang/Core/`: models and services shared by features.
- `AutoLang/Resources/`: asset catalog (app icon, named colors), localized strings.
- `AutoLangTests/`: unit tests.

## Commands

The `DEVELOPER_DIR=` prefix points the build at Xcode even when the Mac's default tools are only the Command Line Tools.

- Generate project: `xcodegen generate`
- Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme AutoLang -configuration Debug -derivedDataPath build build`
- Test: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme AutoLang -derivedDataPath build test`
- Run: `open build/Build/Products/Debug/AutoLang.app`

## Conventions

- Colors come from named colors in the asset catalog, never hex values in code.
- Every user-facing string goes through `Localizable.xcstrings` (Arabic and English).
- A change is done when it builds, the tests pass, and the changed screen was run and seen.
