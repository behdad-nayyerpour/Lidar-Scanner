#!/usr/bin/env bash
# Runs the fusion and projection self-tests on an iOS simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed" >&2
  exit 1
fi

xcodegen generate --spec project.yml

UDID="$(python3 - << 'PY'
import json, subprocess, sys
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
data = json.loads(raw)
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        name = device.get("name", "")
        if device.get("isAvailable") and name.startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit("No available iPhone simulator")
PY
)"

echo "Testing on simulator ${UDID}"
mkdir -p "$ROOT/dist"
xcodebuild test \
  -project "$ROOT/LidarScanner.xcodeproj" \
  -scheme LidarScanner \
  -destination "id=${UDID}" \
  -only-testing:LidarScannerTests \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 120 \
  -resultBundlePath "$ROOT/dist/Tests.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER=""
