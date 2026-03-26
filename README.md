# Deploy Seen

Bash script to standardize local EAS builds and store submissions.

- Selects environment (dev/prod) by overwriting `.env`
- Runs `expo prebuild` for the selected platform
- Runs `eas build --local --non-interactive`
- Optionally submits to TestFlight (iOS) or Internal Testing (Android) via `eas submit`
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

- `./deploy.sh --ios --prod --tf`
  - Same as `--ios --prod` above, plus:
  - Submits the build artifact to **TestFlight** via `eas submit --platform ios`

- `./deploy.sh --android --prod --it`
  - Same as `--android --prod` above, plus:
  - Submits the build artifact to **Google Play Internal Testing** via `eas submit --platform android`

- `./deploy.sh --both --prod`
  - Removes `node_modules`, `ios/`, and `android/` directories
  - Runs shared setup (install, env, prebuild for both platforms)
  - Builds iOS then Android sequentially

- `./deploy.sh --both --prod --tf` (or `--it`)
  - Same as `--both --prod` above, plus:
  - Submits iOS to **TestFlight** and Android to **Internal Testing** after both builds complete

Same logic applies for other platform/environment combinations.

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

### Store submission prerequisites

When using `--tf` or `--it`, additional prerequisites apply:

**iOS (TestFlight):**

- An [Apple Developer account](https://developer.apple.com/account/)
- `ascAppId` configured in the submit profile of `eas.json` (or an App Store Connect API Key)

**Android (Internal Testing):**

- A [Google Play Developer account](https://play.google.com/apps/publish/signup/)
- A [Google Service Account Key](https://github.com/expo/fyi/blob/main/creating-google-service-account.md) configured via EAS credentials
- The app must have been uploaded manually to Google Play Console at least once

> See the [EAS Submit docs](https://docs.expo.dev/submit/introduction/) for full credential setup.

## Submit profiles in eas.json

To enable non-interactive submissions, add a `submit` section to your `eas.json`:

```json
{
  "build": { ... },
  "submit": {
    "production": {
      "ios": {
        "ascAppId": "your-app-store-connect-app-id"
      },
      "android": {
        "track": "internal"
      }
    }
  }
}
```

The script uses the same profile name for both build and submit (matching the `--auto-submit` convention from EAS). You can override it with `--profile <name>`.

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

# Build and submit to TestFlight
./deploy.sh --ios --prod --tf

# Build and submit to Google Play Internal Testing
./deploy.sh --android --prod --it

# Build both platforms
./deploy.sh --both --prod

# Build both platforms + submit to TestFlight & Internal Testing
./deploy.sh --both --prod --tf

# Build both platforms (dev)
./deploy.sh --both --dev
```
