#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"

# -------------------------
# Exit codes (extensible)
# -------------------------
readonly EX_SUCCESS=0
readonly EX_USAGE=2

# Argument / invocation errors
readonly EX_ARG=10
readonly EX_PROJECT=11
readonly EX_ROOT=12

# Tooling / prereq errors
readonly EX_TOOL=20
readonly EX_PREREQ=21

# Config errors (profiles, lockfile expectations, env templates)
readonly EX_CONFIG=30

# Step failures
readonly EX_INSTALL=40
readonly EX_SETENV=41
readonly EX_PREBUILD=42
readonly EX_EAS=50
readonly EX_SUBMIT=51
readonly EX_BUMP=43

# Unhandled
readonly EX_UNEXPECTED=99

timestamp() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

_log() {
  local level="$1"; shift
  local msg="${*:-}"

  if [[ -z "$msg" ]]; then
    printf '%s [%s]\n' "$(timestamp)" "$level"
    return 0
  fi

  # Prefix every line to keep multi-line logs readable.
  while IFS= read -r line; do
    printf '%s [%s] %s\n' "$(timestamp)" "$level" "$line"
  done <<<"$msg"
}
log()  { _log "INFO"  "$*"; }
warn() { _log "WARN"  "$*"; }
err()  { _log "ERROR" "$*"; }

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [--project /path/to/project] --ios|--android|--both --dev|--prod [options]

Required:
  --ios | --android | --both        Target platform (--both builds iOS and Android sequentially)
  --dev | --development             Development environment (uses .env.dev -> .env)
  --prod | --production             Production environment (uses .env.prod -> .env)

Submission:
  --tf                              Submit iOS build to TestFlight (requires --ios or --both)
  --it                              Submit Android build to Internal Testing (requires --android or --both)
                                    With --both, either flag submits both platforms to their respective tracks

Options:
  --project <dir>                   Run from a specific project directory (default: current directory)
  --profile <name>                  Override EAS build/submit profile (default: development for dev, production for prod)

  --env-dev-file <path>             Dev env template file (default: .env.dev)
  --env-prod-file <path>            Prod env template file (default: .env.prod)
  --env-out-file <path>             Output env file written before prebuild (default: .env)

  --bump                            Increment version (patch), buildNumber, and versionCode before build
  --clean                           Remove node_modules BEFORE install when using npm install (skipped for npm ci)
  --force-clean                     Allow removing node_modules even if it is a symlink (safety override)
  --npm-ci                          Force npm ci (requires package-lock.json)
  --npm-install                     Force npm install
  --skip-prereq                     Skip iOS/Android local build prerequisite checks (not recommended)
  --skip-root-check                 Skip project-root sanity checks (not recommended)
  -h, --help                        Show this help

Defaults:
  - If CI=true/1/yes -> npm ci
  - Otherwise -> npm install
  - --both always removes node_modules, ios/, and android/ before building

Examples:
  $SCRIPT_NAME --ios --dev
  $SCRIPT_NAME --ios --development
  $SCRIPT_NAME --project /Users/me/myapp --android --prod
  $SCRIPT_NAME --android --prod --profile staging
  CI=true $SCRIPT_NAME --ios --prod --npm-ci
  $SCRIPT_NAME --ios --prod --tf
  $SCRIPT_NAME --android --prod --it
  $SCRIPT_NAME --both --prod
  $SCRIPT_NAME --both --prod --tf
  $SCRIPT_NAME --both --dev
  $SCRIPT_NAME --ios --dev --bump
EOF
}

die() {
  local code="$1"; shift
  err "$*"
  exit "$code"
}

arg_error() {
  local msg="$1"
  err "$msg"
  usage >&2
  exit "$EX_ARG"
}

on_err() {
  local status="${1:-}"
  local line="${2:-}"
  local cmd="${3:-}"
  err "Unhandled error (exit=$status) at line $line: $cmd"
  exit "$EX_UNEXPECTED"
}
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "$EX_TOOL" "Required command not found in PATH: $cmd"
}

is_ci() {
  case "${CI:-}" in
    1|true|TRUE|True|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

validate_json_file() {
  local file="$1"
  [[ -f "$file" ]] || die "$EX_ROOT" "Required file not found: $file (cwd: $(pwd))"

  # eas.json can include comments in some projects; strip // and /* */ before parsing.
  if [[ "$file" == "eas.json" ]]; then
    FILE="$file" node -e 'const fs=require("fs"); const s=fs.readFileSync(process.env.FILE,"utf8").replace(/\/\/.*$/gm,"").replace(/\/\*[\s\S]*?\*\//g,""); JSON.parse(s);' >/dev/null 2>&1 \
      || die "$EX_ROOT" "$file is not valid JSON (cannot parse)."
  else
    FILE="$file" node -e 'const fs=require("fs"); JSON.parse(fs.readFileSync(process.env.FILE,"utf8"));' >/dev/null 2>&1 \
      || die "$EX_ROOT" "$file is not valid JSON (cannot parse)."
  fi
}

package_has_dep() {
  local dep="$1"
  NODE_DEP="$dep" node -e '
    const fs=require("fs");
    const pkg=JSON.parse(fs.readFileSync("package.json","utf8"));
    const d=process.env.NODE_DEP;
    const has = (pkg.dependencies && pkg.dependencies[d]) || (pkg.devDependencies && pkg.devDependencies[d]);
    process.exit(has ? 0 : 1);
  ' >/dev/null 2>&1
}

eas_profile_exists() {
  local profile="$1"
  NODE_EAS_PROFILE="$profile" node -e '
    const fs=require("fs");
    const eas=JSON.parse(fs.readFileSync("eas.json","utf8").replace(/\/\/.*$/gm,"").replace(/\/\*[\s\S]*?\*\//g,""));
    const p=process.env.NODE_EAS_PROFILE;
    process.exit(eas.build && Object.prototype.hasOwnProperty.call(eas.build, p) ? 0 : 1);
  ' >/dev/null 2>&1
}

eas_profiles_list() {
  node -e '
    const fs=require("fs");
    const eas=JSON.parse(fs.readFileSync("eas.json","utf8").replace(/\/\/.*$/gm,"").replace(/\/\*[\s\S]*?\*\//g,""));
    const keys=Object.keys((eas && eas.build) || {});
    console.log(keys.length ? keys.join(", ") : "(none)");
  '
}

eas_submit_profile_exists() {
  local profile="$1"
  NODE_EAS_PROFILE="$profile" node -e '
    const fs=require("fs");
    const eas=JSON.parse(fs.readFileSync("eas.json","utf8").replace(/\/\/.*$/gm,"").replace(/\/\*[\s\S]*?\*\//g,""));
    const p=process.env.NODE_EAS_PROFILE;
    process.exit(eas.submit && Object.prototype.hasOwnProperty.call(eas.submit, p) ? 0 : 1);
  ' >/dev/null 2>&1
}

# -------------------------
# Timing helpers
# -------------------------
_step_times=""
_current_step_name=""
_current_step_start=0
_deploy_start=0

step_start() {
  _current_step_name="$1"
  _current_step_start=$(date +%s)
}

step_end() {
  local elapsed=$(( $(date +%s) - _current_step_start ))
  _step_times="${_step_times}${_current_step_name}|${elapsed}\n"
}

format_duration() {
  local secs="$1"
  if [[ $secs -ge 60 ]]; then
    printf '%dm %02ds' $((secs / 60)) $((secs % 60))
  else
    printf '%ds' "$secs"
  fi
}

print_timing_summary() {
  local total=$(( $(date +%s) - _deploy_start ))
  log "────────────────────────────────────"
  log "$(printf '%-30s %s' "Step" "Duration")"
  log "────────────────────────────────────"
  while IFS='|' read -r name secs; do
    [[ -z "$name" ]] && continue
    log "$(printf '%-30s %s' "$name" "$(format_duration "$secs")")"
  done < <(printf '%b' "$_step_times")
  log "────────────────────────────────────"
  log "$(printf '%-30s %s' "Total" "$(format_duration "$total")")"
}

# -------------------------
# Version bump helpers
# -------------------------
bump_package_json_version() {
  node -e '
    const fs = require("fs");
    const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
    const parts = (pkg.version || "0.0.0").split(".");
    parts[2] = String(Number(parts[2] || 0) + 1);
    pkg.version = parts.join(".");
    fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");
    console.log(pkg.version);
  ' || die "$EX_BUMP" "Failed to bump package.json version."
}

bump_app_config_version() {
  local new_version="$1"
  local config_file=""

  if [[ -f app.config.ts ]]; then
    config_file="app.config.ts"
  elif [[ -f app.config.js ]]; then
    config_file="app.config.js"
  else
    warn "No app.config.ts or app.config.js found; skipping app config version bump."
    return 0
  fi

  NODE_NEW_VERSION="$new_version" NODE_CONFIG_FILE="$config_file" node -e '
    const fs = require("fs");
    const file = process.env.NODE_CONFIG_FILE;
    const newVer = process.env.NODE_NEW_VERSION;
    let content = fs.readFileSync(file, "utf8");
    let changed = [];

    const verRegex = /(version\s*:\s*)(["'"'"'])(\d+\.\d+\.\d+)\2/;
    if (verRegex.test(content)) {
      content = content.replace(verRegex, (_, pre, q) => pre + q + newVer + q);
      changed.push("version -> " + newVer);
    } else {
      console.error("WARN: version pattern not found in " + file);
    }

    const bnRegex = /(buildNumber\s*:\s*)(["'"'"'])(\d+)\2/;
    if (bnRegex.test(content)) {
      content = content.replace(bnRegex, (_, pre, q, n) => {
        const next = String(Number(n) + 1);
        changed.push("buildNumber -> " + next);
        return pre + q + next + q;
      });
    } else {
      console.error("WARN: buildNumber pattern not found in " + file);
    }

    const vcRegex = /(versionCode\s*:\s*)(\d+)/;
    if (vcRegex.test(content)) {
      content = content.replace(vcRegex, (_, pre, n) => {
        const next = String(Number(n) + 1);
        changed.push("versionCode -> " + next);
        return pre + next;
      });
    } else {
      console.error("WARN: versionCode pattern not found in " + file);
    }

    fs.writeFileSync(file, content);
    if (changed.length) console.log(changed.join(", "));
  ' || die "$EX_BUMP" "Failed to bump app config versions in $config_file."
}

clean_node_modules() {
  if [[ ! -e node_modules ]]; then
    log "node_modules not present; skipping removal."
    return 0
  fi

  # Safety: do not follow symlink by default.
  if [[ -L node_modules && "${FORCE_CLEAN:-0}" -ne 1 ]]; then
    die "$EX_ROOT" "Refusing to remove node_modules because it is a symlink. Use --force-clean to override."
  fi

  log "Removing node_modules (requested via --clean)..."
  rm -rf -- node_modules || die "$EX_ROOT" "Failed to remove node_modules."
  log "node_modules removed."
}

warn_if_git_tracked() {
  local file="$1"
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if git ls-files --error-unmatch "$file" >/dev/null 2>&1; then
    warn "$file is tracked by git. This script overwrites it; consider adding it to .gitignore."
  fi
}

apply_env_file_atomic() {
  local src="$1"
  local dest="$2"

  [[ -f "$src" ]] || die "$EX_CONFIG" "Env template file not found: $src"
  [[ -r "$src" ]] || die "$EX_CONFIG" "Env template file is not readable: $src"

  # Safety: avoid clobbering via symlink.
  if [[ -L "$dest" ]]; then
    die "$EX_ROOT" "Refusing to write $dest because it is a symlink (safety)."
  fi
  if [[ -d "$dest" ]]; then
    die "$EX_ROOT" "Refusing to write $dest because it is a directory."
  fi

  warn_if_git_tracked "$dest"

  local tmp
  tmp="$(mktemp "${dest}.tmp.XXXXXX")" || die "$EX_SETENV" "mktemp failed while preparing to write $dest"
  chmod 600 "$tmp" >/dev/null 2>&1 || true

  if ! cat "$src" > "$tmp"; then
    rm -f -- "$tmp" || true
    die "$EX_SETENV" "Failed to write temp env file from $src"
  fi

  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp" || true
    die "$EX_SETENV" "Failed to move env file into place: $dest"
  fi

  chmod 600 "$dest" >/dev/null 2>&1 || true
}

check_ios_prereqs_pre() {
  local os
  os="$(uname -s)"
  if [[ "$os" != "Darwin" ]]; then
    die "$EX_PREREQ" "iOS local builds require macOS (Darwin). Current OS: $os"
  fi

  require_cmd xcodebuild
  require_cmd xcode-select

  # Expo EAS local builds require CocoaPods and fastlane in the environment. (Doc: local builds prerequisites)
  require_cmd pod
  require_cmd fastlane

  xcodebuild -version >/dev/null 2>&1 \
    || die "$EX_PREREQ" "xcodebuild exists but is not usable. Ensure Xcode is installed and license accepted (sudo xcodebuild -license)."

  xcode-select -p >/dev/null 2>&1 \
    || die "$EX_PREREQ" "Xcode Command Line Tools not configured (xcode-select -p failed)."
}

check_ios_prereqs_post() {
  [[ -d ios ]] || die "$EX_PREBUILD" "iOS project directory (./ios) not found after prebuild."
  # If a Podfile is generated, pod must be present (we already check pre, but keep a sanity check).
  if [[ -f ios/Podfile ]]; then
    require_cmd pod
  fi
}

check_android_prereqs_pre() {
  require_cmd java
  java -version >/dev/null 2>&1 || die "$EX_PREREQ" "java exists but is not usable."

  local sdk
  sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [[ -z "$sdk" ]]; then
    die "$EX_PREREQ" "ANDROID_SDK_ROOT or ANDROID_HOME is not set. Android local builds require the Android SDK."
  fi
  [[ -d "$sdk" ]] || die "$EX_PREREQ" "Android SDK directory not found: $sdk"

  # Ensure sdkmanager is discoverable
  if command -v sdkmanager >/dev/null 2>&1; then
    return 0
  fi

  if [[ -x "$sdk/cmdline-tools/latest/bin/sdkmanager" ]]; then
    export PATH="$sdk/cmdline-tools/latest/bin:$PATH"
  elif [[ -x "$sdk/cmdline-tools/bin/sdkmanager" ]]; then
    export PATH="$sdk/cmdline-tools/bin:$PATH"
  fi

  command -v sdkmanager >/dev/null 2>&1 \
    || die "$EX_PREREQ" "sdkmanager not found. Install Android SDK commandline-tools and ensure sdkmanager is in PATH."
}

check_android_prereqs_post() {
  [[ -d android ]] || die "$EX_PREBUILD" "Android project directory (./android) not found after prebuild."

  if [[ -f android/gradlew ]]; then
    if [[ ! -x android/gradlew ]]; then
      chmod +x android/gradlew >/dev/null 2>&1 || warn "android/gradlew is not executable and chmod failed; build may fail."
    fi
  else
    die "$EX_PREBUILD" "android/gradlew not found after prebuild. Build cannot proceed."
  fi
}

validate_project_root() {
  [[ -f package.json ]] || die "$EX_ROOT" "package.json not found in $(pwd). Run from project root or use --project."
  [[ -f eas.json ]] || die "$EX_ROOT" "eas.json not found in $(pwd). This script expects EAS profiles in eas.json."

  if [[ ! -f app.json && ! -f app.config.js && ! -f app.config.ts && ! -f app.config.json ]]; then
    warn "No app.json/app.config.* found. If this is not the correct project root, rerun with --project."
  fi
}

# -------------------------
# Argument parsing
# -------------------------
PROJECT_DIR=""
PLATFORM=""
ENVIRONMENT=""
PROFILE_OVERRIDE=""

CLEAN_NODE_MODULES=0
FORCE_CLEAN=0
INSTALL_MODE=""        # "npm-ci" or "npm-install"
SKIP_PREREQ=0
SKIP_ROOT_CHECK=0
SUBMIT_MODE=""
BUMP_VERSION=0

# Env file defaults (new behavior)
ENV_DEV_FILE=".env.dev"
ENV_PROD_FILE=".env.prod"
ENV_OUT_FILE=".env"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ -z "$PROJECT_DIR" ]] || arg_error "Flag --project specified multiple times."
      shift
      [[ $# -gt 0 ]] || arg_error "Missing value for --project."
      [[ "$1" != --* ]] || arg_error "Missing value for --project (got another flag: $1)."
      PROJECT_DIR="$1"
      ;;
    --ios)
      [[ -z "$PLATFORM" ]] || arg_error "Conflicting platform flags (already set to \"$PLATFORM\")."
      PLATFORM="ios"
      ;;
    --android)
      [[ -z "$PLATFORM" ]] || arg_error "Conflicting platform flags (already set to \"$PLATFORM\")."
      PLATFORM="android"
      ;;
    --both)
      [[ -z "$PLATFORM" ]] || arg_error "Conflicting platform flags (already set to \"$PLATFORM\")."
      PLATFORM="both"
      ;;
    --dev|--development)
      [[ -z "$ENVIRONMENT" ]] || arg_error "Conflicting environment flags (already set to \"$ENVIRONMENT\")."
      ENVIRONMENT="development"
      ;;
    --prod|--production)
      [[ -z "$ENVIRONMENT" ]] || arg_error "Conflicting environment flags (already set to \"$ENVIRONMENT\")."
      ENVIRONMENT="production"
      ;;
    --profile)
      shift
      [[ $# -gt 0 ]] || arg_error "Missing value for --profile."
      [[ "$1" != --* ]] || arg_error "Missing value for --profile (got another flag: $1)."
      PROFILE_OVERRIDE="$1"
      ;;
    --env-dev-file)
      shift
      [[ $# -gt 0 ]] || arg_error "Missing value for --env-dev-file."
      [[ "$1" != --* ]] || arg_error "Missing value for --env-dev-file (got another flag: $1)."
      ENV_DEV_FILE="$1"
      ;;
    --env-prod-file)
      shift
      [[ $# -gt 0 ]] || arg_error "Missing value for --env-prod-file."
      [[ "$1" != --* ]] || arg_error "Missing value for --env-prod-file (got another flag: $1)."
      ENV_PROD_FILE="$1"
      ;;
    --env-out-file)
      shift
      [[ $# -gt 0 ]] || arg_error "Missing value for --env-out-file."
      [[ "$1" != --* ]] || arg_error "Missing value for --env-out-file (got another flag: $1)."
      ENV_OUT_FILE="$1"
      ;;
    --clean) CLEAN_NODE_MODULES=1 ;;
    --force-clean) FORCE_CLEAN=1 ;;
    --npm-ci|--ci)
      [[ "$INSTALL_MODE" != "npm-install" ]] || arg_error "Cannot combine --npm-ci with --npm-install."
      INSTALL_MODE="npm-ci"
      ;;
    --npm-install)
      [[ "$INSTALL_MODE" != "npm-ci" ]] || arg_error "Cannot combine --npm-install with --npm-ci."
      INSTALL_MODE="npm-install"
      ;;
    --tf)
      [[ -z "$SUBMIT_MODE" ]] || arg_error "Conflicting submit flags (already set to \"$SUBMIT_MODE\")."
      SUBMIT_MODE="testflight"
      ;;
    --it)
      [[ -z "$SUBMIT_MODE" ]] || arg_error "Conflicting submit flags (already set to \"$SUBMIT_MODE\")."
      SUBMIT_MODE="internal"
      ;;
    --bump) BUMP_VERSION=1 ;;
    --skip-prereq) SKIP_PREREQ=1 ;;
    --skip-root-check) SKIP_ROOT_CHECK=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      arg_error "Unknown argument: $1"
      ;;
  esac
  shift
done

[[ -n "$PLATFORM" ]] || arg_error "Platform must be specified (--ios, --android, or --both)."
[[ -n "$ENVIRONMENT" ]] || arg_error "Environment must be specified (--dev/--development or --prod/--production)."

if [[ "$SUBMIT_MODE" == "testflight" && "$PLATFORM" != "ios" && "$PLATFORM" != "both" ]]; then
  arg_error "--tf (TestFlight) requires --ios or --both."
fi
if [[ "$SUBMIT_MODE" == "internal" && "$PLATFORM" != "android" && "$PLATFORM" != "both" ]]; then
  arg_error "--it (Internal Testing) requires --android or --both."
fi

if [[ -n "$PROJECT_DIR" ]]; then
  [[ -d "$PROJECT_DIR" ]] || die "$EX_PROJECT" "Project directory not found: $PROJECT_DIR"
  cd -- "$PROJECT_DIR" || die "$EX_PROJECT" "Cannot cd into project directory: $PROJECT_DIR"
fi

# -------------------------
# Tooling checks
# -------------------------
require_cmd node
require_cmd npm
require_cmd eas

# Root sanity + JSON parsing checks
if [[ "$SKIP_ROOT_CHECK" -ne 1 ]]; then
  validate_project_root
fi
validate_json_file "package.json"
validate_json_file "eas.json"

# This flow is designed for Expo projects (we call expo prebuild).
if ! package_has_dep "expo"; then
  die "$EX_CONFIG" "package.json does not include dependency \"expo\". This script expects an Expo project to run expo prebuild."
fi

# -------------------------
# Derive env/profile
# -------------------------
if [[ "$ENVIRONMENT" == "development" ]]; then
  DEFAULT_PROFILE="development"
  ENV_SRC_FILE="$ENV_DEV_FILE"
else
  DEFAULT_PROFILE="production"
  ENV_SRC_FILE="$ENV_PROD_FILE"
fi

EAS_PROFILE="${PROFILE_OVERRIDE:-$DEFAULT_PROFILE}"

# Validate env template file exists early (fail-fast)
[[ -f "$ENV_SRC_FILE" ]] || die "$EX_CONFIG" "Env template file not found: $ENV_SRC_FILE (configure via --env-dev-file/--env-prod-file)."

# Validate EAS profile exists
if ! eas_profile_exists "$EAS_PROFILE"; then
  die "$EX_CONFIG" "EAS profile \"$EAS_PROFILE\" not found in eas.json (build.*). Available: $(eas_profiles_list)"
fi

SUBMIT_PROFILE=""
if [[ -n "$SUBMIT_MODE" ]]; then
  SUBMIT_PROFILE="$EAS_PROFILE"
  if ! eas_submit_profile_exists "$SUBMIT_PROFILE"; then
    warn "Submit profile \"$SUBMIT_PROFILE\" not found in eas.json (submit.*). eas submit may prompt or fail in non-interactive mode."
  fi
fi

# Decide install mode
if [[ -z "$INSTALL_MODE" ]]; then
  if is_ci; then
    INSTALL_MODE="npm-ci"
  else
    INSTALL_MODE="npm-install"
  fi
fi

log "Deploy started.
cwd=$(pwd)
platform=$PLATFORM
env=$ENVIRONMENT
eas_profile=$EAS_PROFILE
install_mode=$INSTALL_MODE
env_template=$ENV_SRC_FILE
env_out=$ENV_OUT_FILE
clean_node_modules=$CLEAN_NODE_MODULES
skip_prereq=$SKIP_PREREQ
submit_mode=${SUBMIT_MODE:-none}
bump_version=$BUMP_VERSION"

_deploy_start=$(date +%s)

# -------------------------
# Parallel build cleanup (--both)
# -------------------------
if [[ "$PLATFORM" == "both" ]]; then
  if [[ -e node_modules ]]; then
    log "Removing node_modules for parallel build..."
    rm -rf -- node_modules || die "$EX_ROOT" "Failed to remove node_modules."
  fi
  for native_dir in ios android; do
    if [[ -d "$native_dir" ]]; then
      log "Removing ${native_dir}/ for parallel build..."
      rm -rf -- "$native_dir" || die "$EX_ROOT" "Failed to remove ${native_dir}/."
    fi
  done
fi

# -------------------------
# Prereq checks (local builds)
# -------------------------
if [[ "$SKIP_PREREQ" -ne 1 ]]; then
  if [[ "$PLATFORM" == "ios" || "$PLATFORM" == "both" ]]; then
    check_ios_prereqs_pre
  fi
  if [[ "$PLATFORM" == "android" || "$PLATFORM" == "both" ]]; then
    check_android_prereqs_pre
  fi
else
  warn "Skipping prerequisite checks (--skip-prereq). Local builds may fail later with less actionable errors."
fi

# -------------------------
# node_modules cleanup (optional & safer)
# -------------------------
if [[ "$INSTALL_MODE" == "npm-ci" ]]; then
  if [[ "$CLEAN_NODE_MODULES" -eq 1 ]]; then
    log "--clean specified, but install_mode is npm-ci. Skipping explicit node_modules removal (npm ci does a clean install)."
  fi
else
  if [[ "$CLEAN_NODE_MODULES" -eq 1 ]]; then
    clean_node_modules
  else
    log "node_modules cleanup not requested; skipping."
  fi
fi

# -------------------------
# Dependency install
# -------------------------
step_start "npm install"
if [[ "$INSTALL_MODE" == "npm-ci" ]]; then
  [[ -f package-lock.json ]] || die "$EX_CONFIG" "npm ci requested but package-lock.json not found. Commit a lockfile or use --npm-install."
  log "Running npm ci..."
  if ! npm ci --no-audit --no-fund; then
    die "$EX_INSTALL" "npm ci failed."
  fi
  log "npm ci OK."
else
  log "Running npm install..."
  if ! npm install --no-audit --no-fund; then
    die "$EX_INSTALL" "npm install failed."
  fi
  log "npm install OK."
fi
step_end

# -------------------------
# Set env & prebuild (NO package.json scripts)
# -------------------------
step_start "env apply"
log "Applying env: $ENV_SRC_FILE -> $ENV_OUT_FILE ..."
apply_env_file_atomic "$ENV_SRC_FILE" "$ENV_OUT_FILE"
log "Env applied."
step_end

# -------------------------
# Version bump (optional)
# -------------------------
if [[ "$BUMP_VERSION" -eq 1 ]]; then
  step_start "version bump"
  log "Bumping version (patch + buildNumber + versionCode)..."
  NEW_VERSION=$(bump_package_json_version)
  log "package.json version -> $NEW_VERSION"
  BUMP_DETAILS=$(bump_app_config_version "$NEW_VERSION")
  if [[ -n "$BUMP_DETAILS" ]]; then
    log "app config: $BUMP_DETAILS"
  fi
  log "Version bump complete."
  step_end
fi

# Use local Expo CLI (deterministic; no global expo required)
EXPO_BIN="./node_modules/.bin/expo"
if [[ ! -f "$EXPO_BIN" ]]; then
  die "$EX_CONFIG" "Expo CLI binary not found at $EXPO_BIN. Ensure the \"expo\" dependency is installed and npm install succeeded."
fi
if [[ ! -x "$EXPO_BIN" ]]; then
  chmod +x "$EXPO_BIN" >/dev/null 2>&1 || true
fi

if [[ "$PLATFORM" == "both" ]]; then
  step_start "prebuild (ios)"
  log "Running expo prebuild for platform=ios..."
  if ! CI=1 "$EXPO_BIN" prebuild --platform ios; then
    die "$EX_PREBUILD" "expo prebuild (ios) failed."
  fi
  step_end

  step_start "prebuild (android)"
  log "Running expo prebuild for platform=android..."
  if ! CI=1 "$EXPO_BIN" prebuild --platform android; then
    die "$EX_PREBUILD" "expo prebuild (android) failed."
  fi
  step_end
else
  step_start "prebuild ($PLATFORM)"
  log "Running expo prebuild for platform=$PLATFORM..."
  if ! CI=1 "$EXPO_BIN" prebuild --platform "$PLATFORM"; then
    die "$EX_PREBUILD" "expo prebuild failed."
  fi
  step_end
fi
log "Prebuild done."

# Post-prebuild checks
if [[ "$SKIP_PREREQ" -ne 1 ]]; then
  if [[ "$PLATFORM" == "ios" || "$PLATFORM" == "both" ]]; then
    check_ios_prereqs_post
  fi
  if [[ "$PLATFORM" == "android" || "$PLATFORM" == "both" ]]; then
    check_android_prereqs_post
  fi
fi

# -------------------------
# EAS build (& submit)
# -------------------------
if [[ "$PLATFORM" == "both" ]]; then
  # --- iOS build ---
  IOS_ARTIFACT=""
  IOS_BUILD_ARGS=(--platform ios --profile "$EAS_PROFILE" --local --non-interactive)
  if [[ -n "$SUBMIT_MODE" ]]; then
    IOS_ARTIFACT="$(pwd)/deploy-build-ios.ipa"
    IOS_BUILD_ARGS+=(--output "$IOS_ARTIFACT")
  fi

  step_start "eas build (ios)"
  log "[ios] Running eas build ${IOS_BUILD_ARGS[*]}..."
  if ! eas build "${IOS_BUILD_ARGS[@]}"; then
    die "$EX_EAS" "[ios] eas build failed."
  fi
  log "[ios] Build completed."
  step_end

  # --- Android build ---
  ANDROID_ARTIFACT=""
  ANDROID_BUILD_ARGS=(--platform android --profile "$EAS_PROFILE" --local --non-interactive)
  if [[ -n "$SUBMIT_MODE" ]]; then
    ANDROID_ARTIFACT="$(pwd)/deploy-build-android.aab"
    ANDROID_BUILD_ARGS+=(--output "$ANDROID_ARTIFACT")
  fi

  step_start "eas build (android)"
  log "[android] Running eas build ${ANDROID_BUILD_ARGS[*]}..."
  if ! eas build "${ANDROID_BUILD_ARGS[@]}"; then
    die "$EX_EAS" "[android] eas build failed."
  fi
  log "[android] Build completed."
  step_end

  # --- Submit both (if requested) ---
  if [[ -n "$SUBMIT_MODE" ]]; then
    [[ -f "$IOS_ARTIFACT" ]] || die "$EX_SUBMIT" "[ios] Build artifact not found at $IOS_ARTIFACT."
    IOS_SUBMIT_ARGS=(--platform ios --path "$IOS_ARTIFACT" --non-interactive)
    if eas_submit_profile_exists "$SUBMIT_PROFILE"; then
      IOS_SUBMIT_ARGS+=(--profile "$SUBMIT_PROFILE")
    fi

    step_start "submit (ios)"
    log "[ios] Submitting to testflight (eas submit ${IOS_SUBMIT_ARGS[*]})..."
    if ! eas submit "${IOS_SUBMIT_ARGS[@]}"; then
      err "[ios] Build artifact preserved at: $IOS_ARTIFACT"
      die "$EX_SUBMIT" "[ios] eas submit failed."
    fi
    log "[ios] Submission to testflight completed."
    step_end

    [[ -f "$ANDROID_ARTIFACT" ]] || die "$EX_SUBMIT" "[android] Build artifact not found at $ANDROID_ARTIFACT."
    ANDROID_SUBMIT_ARGS=(--platform android --path "$ANDROID_ARTIFACT" --non-interactive)
    if eas_submit_profile_exists "$SUBMIT_PROFILE"; then
      ANDROID_SUBMIT_ARGS+=(--profile "$SUBMIT_PROFILE")
    fi

    step_start "submit (android)"
    log "[android] Submitting to internal (eas submit ${ANDROID_SUBMIT_ARGS[*]})..."
    if ! eas submit "${ANDROID_SUBMIT_ARGS[@]}"; then
      err "[android] Build artifact preserved at: $ANDROID_ARTIFACT"
      die "$EX_SUBMIT" "[android] eas submit failed."
    fi
    log "[android] Submission to internal completed."
    step_end
  fi
else
  # Single-platform build
  BUILD_ARTIFACT=""
  EAS_BUILD_ARGS=(--platform "$PLATFORM" --profile "$EAS_PROFILE" --local --non-interactive)

  if [[ -n "$SUBMIT_MODE" ]]; then
    if [[ "$PLATFORM" == "ios" ]]; then
      BUILD_ARTIFACT="$(pwd)/deploy-build.ipa"
    else
      BUILD_ARTIFACT="$(pwd)/deploy-build.aab"
    fi
    EAS_BUILD_ARGS+=(--output "$BUILD_ARTIFACT")
  fi

  step_start "eas build ($PLATFORM)"
  log "Running eas build ${EAS_BUILD_ARGS[*]}..."
  if ! eas build "${EAS_BUILD_ARGS[@]}"; then
    die "$EX_EAS" "eas build failed."
  fi
  step_end

  # -------------------------
  # EAS submit (TestFlight / Internal Testing)
  # -------------------------
  if [[ -n "$SUBMIT_MODE" ]]; then
    [[ -f "$BUILD_ARTIFACT" ]] || die "$EX_SUBMIT" "Build artifact not found at $BUILD_ARTIFACT after successful build."

    EAS_SUBMIT_ARGS=(--platform "$PLATFORM" --path "$BUILD_ARTIFACT" --non-interactive)
    if eas_submit_profile_exists "$SUBMIT_PROFILE"; then
      EAS_SUBMIT_ARGS+=(--profile "$SUBMIT_PROFILE")
    fi

    step_start "submit ($PLATFORM)"
    log "Submitting build to ${SUBMIT_MODE} (eas submit ${EAS_SUBMIT_ARGS[*]})..."
    if ! eas submit "${EAS_SUBMIT_ARGS[@]}"; then
      err "Build artifact preserved at: $BUILD_ARTIFACT"
      die "$EX_SUBMIT" "eas submit failed."
    fi
    log "Submission to ${SUBMIT_MODE} completed successfully."
    step_end
  fi
fi

print_timing_summary
log "Deploy finished successfully."
exit "$EX_SUCCESS"
