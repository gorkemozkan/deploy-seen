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

# Config errors (scripts, profiles, lockfile expectations)
readonly EX_CONFIG=30

# Step failures
readonly EX_INSTALL=40
readonly EX_SETENV=41
readonly EX_PREBUILD=42
readonly EX_EAS=50

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
  $SCRIPT_NAME [--project /path/to/project] --ios|--android --dev|--prod [options]

Required:
  --ios | --android          Target platform
  --dev | --prod             Target environment

Options:
  --project <dir>            Run from a specific project directory (default: current directory)
  --profile <name>           Override EAS build profile (default: development for --dev, production for --prod)
  --clean                    Remove node_modules BEFORE install when using npm install (skipped for npm ci)
  --force-clean              Allow removing node_modules even if it is a symlink (safety override)
  --npm-ci                   Force npm ci (requires package-lock.json)
  --npm-install              Force npm install
  --skip-prereq              Skip iOS/Android local build prerequisite checks (not recommended)
  --skip-root-check          Skip project-root sanity checks (not recommended)
  -h, --help                 Show this help

Defaults:
  - If CI=true/1/yes -> npm ci
  - Otherwise -> npm install

Examples:
  $SCRIPT_NAME --ios --dev
  $SCRIPT_NAME --project /Users/me/myapp --android --prod
  $SCRIPT_NAME --android --prod --profile staging
  CI=true $SCRIPT_NAME --ios --prod --npm-ci
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
  if [[ "$file" == "eas.json" ]]; then
    FILE="$file" node -e 'const fs=require("fs"); const s=fs.readFileSync(process.env.FILE,"utf8").replace(/\/\/.*$/gm,"").replace(/\/\*[\s\S]*?\*\//g,""); JSON.parse(s);' >/dev/null 2>&1 \
      || die "$EX_ROOT" "$file is not valid JSON (cannot parse)."
  else
    FILE="$file" node -e 'const fs=require("fs"); JSON.parse(fs.readFileSync(process.env.FILE,"utf8"));' >/dev/null 2>&1 \
      || die "$EX_ROOT" "$file is not valid JSON (cannot parse)."
  fi
}

npm_script_exists() {
  local script="$1"
  NODE_SCRIPT_NAME="$script" node -e '
    const fs=require("fs");
    const pkg=JSON.parse(fs.readFileSync("package.json","utf8"));
    const s=process.env.NODE_SCRIPT_NAME;
    process.exit(pkg.scripts && Object.prototype.hasOwnProperty.call(pkg.scripts, s) ? 0 : 1);
  ' >/dev/null 2>&1
}

require_npm_script() {
  local script="$1"
  if ! npm_script_exists "$script"; then
    die "$EX_CONFIG" "npm script not found in package.json: \"$script\""
  fi
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

clean_node_modules() {
  if [[ ! -e node_modules ]]; then
    log "INFO" "node_modules not present; skipping removal."
    return 0
  fi

  # Safety: do not follow symlink by default.
  if [[ -L node_modules && "${FORCE_CLEAN:-0}" -ne 1 ]]; then
    die "$EX_ROOT" "Refusing to remove node_modules because it is a symlink. Use --force-clean to override."
  fi

  log "INFO" "Removing node_modules (requested via --clean)..."
  rm -rf -- node_modules || die "$EX_ROOT" "Failed to remove node_modules."
  log "INFO" "node_modules removed."
}

check_ios_prereqs_pre() {
  local os
  os="$(uname -s)"
  if [[ "$os" != "Darwin" ]]; then
    die "$EX_PREREQ" "iOS local builds require macOS (Darwin). Current OS: $os"
  fi

  require_cmd xcodebuild
  require_cmd xcode-select

  xcodebuild -version >/dev/null 2>&1 \
    || die "$EX_PREREQ" "xcodebuild exists but is not usable. Ensure Xcode is installed and license accepted (sudo xcodebuild -license)."

  xcode-select -p >/dev/null 2>&1 \
    || die "$EX_PREREQ" "Xcode Command Line Tools not configured (xcode-select -p failed)."
}

check_ios_prereqs_post() {
  [[ -d ios ]] || die "$EX_PREBUILD" "iOS project directory (./ios) not found after prebuild."
  if [[ -f ios/Podfile ]]; then
    require_cmd pod
  else
    warn "ios/Podfile not found after prebuild. If eas build fails, verify your prebuild scripts generate the iOS project."
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
  # Strong checks to reduce “wrong folder” accidents.
  [[ -f package.json ]] || die "$EX_ROOT" "package.json not found in $(pwd). Run from project root or use --project."
  [[ -f eas.json ]] || die "$EX_ROOT" "eas.json not found in $(pwd). This script expects EAS profiles in eas.json."

  # Heuristic: warn if no app config; still proceed.
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
    --dev)
      [[ -z "$ENVIRONMENT" ]] || arg_error "Conflicting environment flags (already set to \"$ENVIRONMENT\")."
      ENVIRONMENT="development"
      ;;
    --prod)
      [[ -z "$ENVIRONMENT" ]] || arg_error "Conflicting environment flags (already set to \"$ENVIRONMENT\")."
      ENVIRONMENT="production"
      ;;
    --profile)
      shift
      [[ $# -gt 0 ]] || arg_error "Missing value for --profile."
      [[ "$1" != --* ]] || arg_error "Missing value for --profile (got another flag: $1)."
      PROFILE_OVERRIDE="$1"
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

[[ -n "$PLATFORM" ]] || arg_error "Platform must be specified (--ios or --android)."
[[ -n "$ENVIRONMENT" ]] || arg_error "Environment must be specified (--dev or --prod)."

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

# -------------------------
# Derive scripts/profile
# -------------------------
if [[ "$ENVIRONMENT" == "development" ]]; then
  SET_ENV_SCRIPT="set-env:dev"
  DEFAULT_PROFILE="development"
else
  SET_ENV_SCRIPT="set-env:prod"
  DEFAULT_PROFILE="production"
fi

PREBUILD_SCRIPT="prebuild:${ENVIRONMENT}:${PLATFORM}"
EAS_PROFILE="${PROFILE_OVERRIDE:-$DEFAULT_PROFILE}"

# Validate npm scripts exist early (also helps avoid running in wrong directory)
require_npm_script "$SET_ENV_SCRIPT"
require_npm_script "$PREBUILD_SCRIPT"

# Validate EAS profile exists
if ! eas_profile_exists "$EAS_PROFILE"; then
  die "$EX_CONFIG" "EAS profile \"$EAS_PROFILE\" not found in eas.json (build.*). Available: $(eas_profiles_list)"
fi

# Decide install mode
if [[ -z "$INSTALL_MODE" ]]; then
  if is_ci; then
    INSTALL_MODE="npm-ci"
  else
    INSTALL_MODE="npm-install"
  fi
fi

log "INFO" "Deploy started.
cwd=$(pwd)
platform=$PLATFORM
env=$ENVIRONMENT
eas_profile=$EAS_PROFILE
install_mode=$INSTALL_MODE
clean_node_modules=$CLEAN_NODE_MODULES
skip_prereq=$SKIP_PREREQ"

# -------------------------
# Prereq checks (local builds)
# -------------------------
if [[ "$SKIP_PREREQ" -ne 1 ]]; then
  if [[ "$PLATFORM" == "ios" ]]; then
    check_ios_prereqs_pre
  else
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
    log "INFO" "--clean specified, but install_mode is npm-ci. Skipping explicit node_modules removal (npm ci does a clean install)."
  fi
else
  if [[ "$CLEAN_NODE_MODULES" -eq 1 ]]; then
    clean_node_modules
  else
    log "INFO" "node_modules cleanup not requested; skipping."
  fi
fi

# -------------------------
# Dependency install
# -------------------------
if [[ "$INSTALL_MODE" == "npm-ci" ]]; then
  [[ -f package-lock.json ]] || die "$EX_CONFIG" "npm ci requested but package-lock.json not found. Commit a lockfile or use --npm-install."
  log "INFO" "Running npm ci..."
  if ! npm ci --no-audit --no-fund; then
    die "$EX_INSTALL" "npm ci failed."
  fi
  log "INFO" "npm ci OK."
else
  log "INFO" "Running npm install..."
  if ! npm install --no-audit --no-fund; then
    die "$EX_INSTALL" "npm install failed."
  fi
  log "INFO" "npm install OK."
fi

# -------------------------
# Set env & prebuild
# -------------------------
log "INFO" "Running npm run $SET_ENV_SCRIPT..."
if ! npm run "$SET_ENV_SCRIPT"; then
  die "$EX_SETENV" "npm run $SET_ENV_SCRIPT failed."
fi
log "INFO" "Env set."

log "INFO" "Running npm run $PREBUILD_SCRIPT..."
if ! npm run "$PREBUILD_SCRIPT"; then
  die "$EX_PREBUILD" "npm run $PREBUILD_SCRIPT failed."
fi
log "INFO" "Prebuild done."

# Post-prebuild checks
if [[ "$SKIP_PREREQ" -ne 1 ]]; then
  if [[ "$PLATFORM" == "ios" ]]; then
    check_ios_prereqs_post
  else
    check_android_prereqs_post
  fi
fi

# -------------------------
# EAS build
# -------------------------
log "INFO" "Running eas build --platform $PLATFORM --profile $EAS_PROFILE --local --non-interactive..."
if ! eas build --platform "$PLATFORM" --profile "$EAS_PROFILE" --local --non-interactive; then
  die "$EX_EAS" "eas build failed."
fi

log "INFO" "Deploy finished successfully."
exit "$EX_SUCCESS"
