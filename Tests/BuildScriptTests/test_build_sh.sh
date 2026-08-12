#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-build-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -F -- "$expected" "$file" >/dev/null || fail "missing '$expected' in $file"
}

make_fixture() {
  local name="$1"
  local fixture="$TEST_ROOT/$name"

  mkdir -p "$fixture/bin" "$fixture/project/scripts"
  cp "$ROOT_DIR/build.sh" "$fixture/project/build.sh"
  chmod +x "$fixture/project/build.sh"

  cat >"$fixture/project/scripts/bootstrap_ocr_runtime.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$fixture/project/scripts/bootstrap_ocr_runtime.sh"

  cat >"$fixture/bin/security" <<'EOF'
#!/bin/bash
if [ "${MOCK_SECURITY_HAS_IDENTITY:-1}" = "1" ]; then
  printf '  1) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "%s"\n' "${MOCK_IDENTITY_NAME:-Apple Development: Test User (TEAMID1234)}"
  printf '     1 valid identities found\n'
else
  printf '     0 valid identities found\n'
fi
EOF

  cat >"$fixture/bin/xcodegen" <<'EOF'
#!/bin/bash
exit 0
EOF

  cat >"$fixture/bin/xcodebuild" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$MOCK_XCODEBUILD_ARGS"
app="$PWD/build/Build/Products/Release/ToolBox.app"
mkdir -p "$app/Contents/MacOS"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.youtonghy.toolbox</string>
</dict></plist>
PLIST
printf 'new-build\n' >"$app/Contents/MacOS/ToolBox"
EOF

  cat >"$fixture/bin/codesign" <<'EOF'
#!/bin/bash
exit 0
EOF

  cat >"$fixture/bin/open" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >"$MOCK_OPEN_PATH"
EOF

  cat >"$fixture/bin/pgrep" <<'EOF'
#!/bin/bash
if [ "${MOCK_PROCESS_RUNNING:-0}" = "1" ]; then
  exit 0
fi
exit 1
EOF

  cat >"$fixture/bin/pkill" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$MOCK_PKILL_LOG"
exit 0
EOF

  chmod +x "$fixture/bin/"*
  printf '%s\n' "$fixture"
}

test_locks_identity_and_updates_installed_bundle_in_place() {
  local fixture
  fixture="$(make_fixture stable-identity)"
  local project="$fixture/project"
  local install_app="$fixture/install/ToolBox.app"
  local identity_file="$fixture/state/signing-identity"

  mkdir -p "$install_app/Contents"
  printf 'stale\n' >"$install_app/Contents/stale.txt"

  PATH="$fixture/bin:$PATH" \
    MOCK_XCODEBUILD_ARGS="$fixture/xcodebuild.args" \
    MOCK_OPEN_PATH="$fixture/open.path" \
    SIGN_IDENTITY_FILE="$identity_file" \
    INSTALL_APP_PATH="$install_app" \
    "$project/build.sh" >"$fixture/output.log" 2>&1

  [ ! -e "$install_app/Contents/stale.txt" ] || fail "stale installed content was not removed"
  [ -z "$(find "$fixture/install" -maxdepth 1 -name 'ToolBox.app.old.*' -print -quit)" ] || fail "old bundle was not cleaned up"
  [ "$(cat "$install_app/Contents/MacOS/ToolBox")" = "new-build" ] || fail "new app was not installed"
  [ "$(cat "$identity_file")" = "ABCDEF0123456789ABCDEF0123456789ABCDEF01" ] || fail "signing identity was not locked"
  [ "$(cat "$fixture/open.path")" = "$install_app" ] || fail "script did not open the installed app"
  assert_contains "$fixture/xcodebuild.args" "CODE_SIGN_IDENTITY=ABCDEF0123456789ABCDEF0123456789ABCDEF01"
  assert_contains "$fixture/xcodebuild.args" "CODE_SIGN_STYLE=Manual"
  assert_contains "$fixture/xcodebuild.args" "DEVELOPMENT_TEAM="
  assert_contains "$fixture/xcodebuild.args" "PROVISIONING_PROFILE_SPECIFIER="
  assert_contains "$fixture/xcodebuild.args" "PRODUCT_BUNDLE_IDENTIFIER=com.youtonghy.toolbox"
}

test_refuses_implicit_ad_hoc_signing() {
  local fixture
  fixture="$(make_fixture missing-identity)"

  if PATH="$fixture/bin:$PATH" \
    MOCK_SECURITY_HAS_IDENTITY=0 \
    MOCK_PROCESS_RUNNING=1 \
    MOCK_PKILL_LOG="$fixture/pkill.log" \
    MOCK_XCODEBUILD_ARGS="$fixture/xcodebuild.args" \
    MOCK_OPEN_PATH="$fixture/open.path" \
    SIGN_IDENTITY_FILE="$fixture/state/signing-identity" \
    INSTALL_APP_PATH="$fixture/install/ToolBox.app" \
    "$fixture/project/build.sh" >"$fixture/output.log" 2>&1; then
    fail "build unexpectedly succeeded without a signing identity"
  fi

  assert_contains "$fixture/output.log" "ALLOW_ADHOC=1"
  [ ! -e "$fixture/xcodebuild.args" ] || fail "xcodebuild ran without a stable signing identity"
  [ ! -e "$fixture/pkill.log" ] || fail "running app was stopped before signing validation"
}

test_self_signed_identity_disables_library_validation() {
  local fixture
  fixture="$(make_fixture self-signed)"

  PATH="$fixture/bin:$PATH" \
    MOCK_IDENTITY_NAME=youtonghy \
    MOCK_XCODEBUILD_ARGS="$fixture/xcodebuild.args" \
    MOCK_OPEN_PATH="$fixture/open.path" \
    SIGN_IDENTITY_FILE="$fixture/state/signing-identity" \
    INSTALL_APP_PATH="$fixture/install/ToolBox.app" \
    CODE_SIGN_IDENTITY=youtonghy \
    OPEN=0 \
    "$fixture/project/build.sh" >"$fixture/output.log" 2>&1

  assert_contains "$fixture/xcodebuild.args" "CODE_SIGN_ENTITLEMENTS=Resources/ToolBox-AdHoc.entitlements"
}

test_defaults_to_system_applications_directory() {
  assert_contains "$ROOT_DIR/build.sh" 'INSTALL_APP_PATH="${INSTALL_APP_PATH:-/Applications/ToolBox.app}"'
}

test_locks_identity_and_updates_installed_bundle_in_place
test_refuses_implicit_ad_hoc_signing
test_self_signed_identity_disables_library_validation
test_defaults_to_system_applications_directory
echo "PASS: build.sh behavior"
