#!/bin/bash
# PlayPort macOS environment preflight.
# Run this on the target Intel iMac from the PlayPort repository root.
# It prepares/verifies the non-MFi layers and deliberately does not create or
# copy an accessory identity.

set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/macos/bt-bridge"
REPORT="$ROOT_DIR/macos/preflight-report.txt"
cd "$ROOT_DIR"

exec > >(tee "$REPORT") 2>&1

echo "PlayPort macOS preflight"
echo "timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "repo: $ROOT_DIR"
echo

echo '=== host ==='
uname -m || true
sw_vers || true
echo "xcode-select: $(xcode-select -p 2>/dev/null || echo missing)"
node -v 2>/dev/null || echo 'node: missing'
npm -v 2>/dev/null || echo 'npm: missing'

echo
echo '=== JDK 21 ==='
if ! command -v brew >/dev/null 2>&1; then
  echo 'brew: missing'
else
  if ! brew list --versions openjdk@21 >/dev/null 2>&1; then
    echo 'Installing openjdk@21 with Homebrew...'
    brew install openjdk@21
  fi
fi

JAVA_HOME_21="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
if [ -z "$JAVA_HOME_21" ] && command -v brew >/dev/null 2>&1; then
  BREW_JDK="$(brew --prefix openjdk@21 2>/dev/null || true)"
  if [ -n "$BREW_JDK" ] && [ -d "$BREW_JDK/libexec" ]; then
    JAVA_HOME_21="$BREW_JDK/libexec"
  fi
fi

if [ -z "$JAVA_HOME_21" ]; then
  echo 'JDK21: FAIL (JDK 21 not found)'
  JDK21_STATUS=FAIL
else
  export JAVA_HOME="$JAVA_HOME_21"
  export PATH="$JAVA_HOME/bin:$PATH"
  java -version
  if java -version 2>&1 | grep -Eq 'version "21([.]|$)'; then
    echo 'JDK21: PASS'
    JDK21_STATUS=PASS
  else
    echo 'JDK21: FAIL (java is not version 21)'
    JDK21_STATUS=FAIL
  fi
  ./gradlew --version || true
fi

echo
echo '=== PlayPort JVM build ==='
if [ "$JDK21_STATUS" = PASS ]; then
  if ./gradlew build; then
    PLAYPORT_BUILD_STATUS=PASS
  else
    PLAYPORT_BUILD_STATUS=FAIL
  fi
else
  echo 'Skipped because JDK21 failed.'
  PLAYPORT_BUILD_STATUS=FAIL
fi

echo
echo '=== Web client ==='
if (cd "$ROOT_DIR/web" && npm install && npm test); then
  WEB_TEST_STATUS=PASS
else
  WEB_TEST_STATUS=FAIL
fi
if (cd "$ROOT_DIR/web" && npm run build); then
  WEB_BUILD_STATUS=PASS
else
  WEB_BUILD_STATUS=FAIL
fi

echo
echo '=== macOS Bluetooth bridge ==='
if (cd "$BRIDGE_DIR" && ./build.sh); then
  BT_BUILD_STATUS=PASS
else
  BT_BUILD_STATUS=FAIL
fi

BT_RUNTIME_STATUS=FAIL
if [ -x "$BRIDGE_DIR/bt-bridge" ]; then
  file "$BRIDGE_DIR/bt-bridge"
  if file "$BRIDGE_DIR/bt-bridge" | grep -Eq 'Mach-O 64-bit executable x86_64'; then
    if "$BRIDGE_DIR/bt-bridge" --print-address; then
      BT_RUNTIME_STATUS=PASS
    fi
  else
    echo 'BT_BRIDGE_INTEL_RUNTIME: FAIL (binary is not x86_64 Mach-O)'
  fi
else
  echo 'bt-bridge binary missing'
fi

echo
echo '=== Wi-Fi, Bluetooth, Bonjour, firewall ==='
networksetup -listallhardwareports || true
networksetup -getairportnetwork en0 2>/dev/null || true
if ifconfig en0 >/dev/null 2>&1; then
  MAC_WIFI_STATUS=PASS
else
  MAC_WIFI_STATUS=FAIL
fi
system_profiler SPBluetoothDataType || true
if system_profiler SPBluetoothDataType 2>/dev/null | grep -Eiq 'state:|address:|manufacturer:'; then
  MAC_BT_STATUS=PASS
else
  MAC_BT_STATUS=FAIL
fi

MDNS_STATUS=FAIL
if command -v dns-sd >/dev/null 2>&1; then
  MDNS_STATUS=PASS
  echo 'dns-sd: available'
  echo 'Run separately for a live browse: dns-sd -B _airplay._tcp local'
else
  echo 'dns-sd: missing'
fi

echo 'Listening TCP ports:'
lsof -nP -iTCP:7000 -sTCP:LISTEN || true
lsof -nP -iTCP:8080 -sTCP:LISTEN || true
echo 'Firewall state:'
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || true
echo 'Manual permission checks required:'
echo '  System Settings > Privacy & Security > Bluetooth: enable the Terminal/Codex app.'
echo '  System Settings > General > AirDrop & Handoff: turn off AirPlay Receiver if port 7000 is occupied.'

echo
echo '=== Bluetooth layer ==='
echo 'The bridge exposes the real commands:'
echo '  bt-bridge --list'
echo '  bt-bridge --scan'
echo '  bt-bridge --pair <iPhone Bluetooth address>'
echo 'Do not mark BT_PAIR_LAYER as PASS until --scan or --pair completes on the iMac.'
BT_PAIR_STATUS=NOT_TESTED

echo
echo '=== MFi (intentionally separate) ==='
if [ -f "$ROOT_DIR/identity/offline-mfi/identity.pk8" ] && [ -f "$ROOT_DIR/identity/offline-mfi/certificate.p7b" ]; then
  echo 'AUTH_METHOD: USER_OWNED_MFI_IDENTITY (credentials present; provenance must be verified separately)'
else
  echo 'AUTH_METHOD: BLOCKED (no local identity; use user-owned credentials or --mfi-server)'
fi

echo
echo '=== status ==='
cat <<EOF
JDK21: $JDK21_STATUS
PLAYPORT_BUILD: $PLAYPORT_BUILD_STATUS
WEB_BUILD: $WEB_BUILD_STATUS
BT_BRIDGE_BUILD: $BT_BUILD_STATUS
BT_BRIDGE_INTEL_RUNTIME: $BT_RUNTIME_STATUS
MAC_WIFI: $MAC_WIFI_STATUS
MAC_BLUETOOTH: $MAC_BT_STATUS
MDNS: $MDNS_STATUS
BT_PAIR_LAYER: $BT_PAIR_STATUS
AUTH: BLOCKED_OR_EXTERNAL
EOF

echo
echo "Report written to $REPORT"
