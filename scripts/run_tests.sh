#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

echo "=== Running VoiceIME Unit Tests ==="
swiftc \
    $(find Sources/VoiceIME -name "*.swift" ! -name "VoiceIMEApp.swift") \
    Tests/VoiceIMETests/TestRunner.swift \
    -o /tmp/voiceime_test_runner

/tmp/voiceime_test_runner
rm -f /tmp/voiceime_test_runner
