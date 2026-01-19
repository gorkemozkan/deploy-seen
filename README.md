# EAS Local Deploy Script

A small, safer wrapper around `npm` + `eas build --local` to standardize builds and reduce common footguns:

- Prevents conflicting flags
- Validates `--project` values
- Optional/safe `node_modules` cleanup
- Uses `npm ci` in CI by default (deterministic installs)
- Validates required npm scripts exist before running
- Preflight checks for iOS/Android local build dependencies
- Validates EAS build profile exists in `eas.json`
- Multi-line safe logging
- Structured exit codes

## Requirements

General:

- Bash
- Node.js + npm
- `eas` CLI (`npm i -g @expo/eas-cli`)

iOS local builds:

- macOS
- Xcode (`xcodebuild`)
- Xcode Command Line Tools (`xcode-select`)
- CocoaPods (`pod`) if your iOS project uses a Podfile

Android local builds:

- Java (`java`)
- Android SDK (`ANDROID_SDK_ROOT` or `ANDROID_HOME`)
- `sdkmanager` available in PATH (via Android commandline-tools)

## Expected npm scripts

This script assumes your `package.json` contains:

- `set-env:dev`
- `set-env:prod`
- `prebuild:development:ios`
- `prebuild:production:ios`
- `prebuild:development:android`
- `prebuild:production:android`

If your project uses different names, you can either:

- rename your scripts to match, or
- fork/adjust the script mapping.

## Usage

```bash
./deploy --ios --dev
./deploy --android --prod
./deploy --project /path/to/project --ios --prod
```
