# EAS Local Deploy Script (with Expo Prebuild + Env Switching)

This repository provides a Bash script to standardize local EAS builds:

- Selects environment (dev/prod) by overwriting `.env`
- Runs `expo prebuild` for the selected platform
- Runs `eas build --local --non-interactive`
- Provides safer defaults (conflicting flags detection, optional node_modules cleanup, deterministic installs in CI, etc.)

## What this script does

When you run:

- `./deploy.sh --ios --dev` (or `--development`)

  - Writes `.env.dev` into `.env`
  - Runs `expo prebuild --platform ios`
  - Runs `eas build --platform ios --profile development --local --non-interactive`

- `./deploy.sh --ios --prod` (or `--production`)
  - Writes `.env.prod` into `.env`
  - Runs `expo prebuild --platform ios`
  - Runs `eas build --platform ios --profile production --local --non-interactive`

Same logic applies for `--android`.

## Requirements

General:

- Bash
- Node.js + npm
- EAS CLI (`eas`) available in PATH (install and login before running local builds)

iOS local builds:

- macOS
- Xcode + Command Line Tools (`xcodebuild`, `xcode-select`)
- CocoaPods (`pod`)
- fastlane (`fastlane`)

Android local builds:

- Java (`java`)
- Android SDK (`ANDROID_SDK_ROOT` or `ANDROID_HOME`)
- `sdkmanager` available (Android commandline-tools)

> Note: Local EAS builds require your machine to have the necessary native build toolchain installed.

## Environment files

By default, the script expects:

- `.env.dev` (development template)
- `.env.prod` (production template)

It overwrites:

- `.env` (default output file)

You can override these paths:

- `--env-dev-file <path>`
- `--env-prod-file <path>`
- `--env-out-file <path>`

## Usage

```bash
chmod +x ./deploy.sh

# iOS dev
./deploy.sh --ios --dev

# iOS prod
./deploy.sh --ios --prod

# Android dev (alias)
./deploy.sh --android --development

# Android prod (alias)
./deploy.sh --android --production

# Run from a different directory
./deploy.sh --project /path/to/project --ios --dev

# Override EAS profile
./deploy.sh --android --prod --profile staging
```
