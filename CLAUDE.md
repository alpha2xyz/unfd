# unfd

Switches the keyboard language by itself and fixes text typed in the wrong layout (⌥⇧Space). Called AutoLang until 0.4.0: the Swift module (`PRODUCT_MODULE_NAME: AutoLang`), the tests and the bundle ID (`com.alpha2xyz.autolang`, so saved settings carry over) keep that name; the project, scheme, target and app are `unfd`.

This file is public-safe: it holds only facts a contributor needs to build and change the app. Private notes live in the workspace folder above this repo, never in this repo.

## Stack

- macOS 14.0+, SwiftUI, Swift 6.0.
- The Xcode project is generated from `project.yml` by XcodeGen. Never edit `unfd.xcodeproj` by hand; it is gitignored. Change `project.yml`, then run `xcodegen generate`.

## Layout

- `unfd/App/`: app entry point (`@main`) and app-wide settings.
- `unfd/Features/<Feature>/`: one folder per screen or feature (view + its logic).
- `unfd/Core/`: models and services shared by features.
- `unfd/Resources/`: asset catalog (app icon, named colors), localized strings.
- `AutoLangTests/`: unit tests.

## Commands

The `DEVELOPER_DIR=` prefix points the build at Xcode even when the Mac's default tools are only the Command Line Tools.

- Generate project: `xcodegen generate`
- Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme unfd -configuration Debug -derivedDataPath build build`
- Test: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme unfd -derivedDataPath build test`
- Run: `open build/Build/Products/Debug/unfd.app`

## Conventions

- Colors come from named colors in the asset catalog, never hex values in code.
- Every user-facing string goes through `Localizable.xcstrings` (Arabic and English).
- A change is done when it builds, the tests pass, and the changed screen was run and seen.
