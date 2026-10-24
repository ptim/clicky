#!/bin/bash
set -euo pipefail

# =============================================================================
# build-clicky-launcher-app.sh — Builds "Clicky Launcher.app", which starts the
# local Cloudflare Worker and then opens Clicky
#
# The app is a small AppleScript applet that runs
# start-clicky-with-local-worker.sh from this checkout in the background and
# quits immediately. The script's absolute path is compiled into the app, so
# rebuild the app if you move the repository.
#
# Usage:
#   ./scripts/build-clicky-launcher-app.sh                Installs to ~/Applications
#   ./scripts/build-clicky-launcher-app.sh /Applications  Installs to another folder
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCH_SCRIPT_PATH="${PROJECT_DIR}/scripts/start-clicky-with-local-worker.sh"
OUTPUT_DIR="${1:-${HOME}/Applications}"
LAUNCHER_APP_PATH="${OUTPUT_DIR}/Clicky Launcher.app"
CLICKY_BUNDLE_IDENTIFIER="com.ptim.leanring-buddy"

chmod +x "${LAUNCH_SCRIPT_PATH}"
mkdir -p "${OUTPUT_DIR}"

# `do shell script` waits for the command's output to close, so the launch
# script is detached with nohup and its output sent to the log. The applet then
# quits at once instead of staying in the Dock for as long as Clicky runs.
APPLESCRIPT_SOURCE="do shell script \"nohup /bin/bash \" & quoted form of \"${LAUNCH_SCRIPT_PATH}\" & \" > \\\"\$HOME/Library/Logs/Clicky/launcher.log\\\" 2>&1 &\""

mkdir -p "${HOME}/Library/Logs/Clicky"
rm -rf "${LAUNCHER_APP_PATH}"
osacompile -o "${LAUNCHER_APP_PATH}" -e "${APPLESCRIPT_SOURCE}"

# Hide the applet from the Dock while it runs (it only lives for a moment)
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "${LAUNCHER_APP_PATH}/Contents/Info.plist"

# Borrow Clicky's icon if an installed copy of the app can be found
CLICKY_APP_PATH="$(mdfind "kMDItemCFBundleIdentifier == '${CLICKY_BUNDLE_IDENTIFIER}'" | grep -v '/DerivedData/' | head -1 || true)"
if [ -n "${CLICKY_APP_PATH}" ] && [ -f "${CLICKY_APP_PATH}/Contents/Resources/AppIcon.icns" ]; then
    cp "${CLICKY_APP_PATH}/Contents/Resources/AppIcon.icns" "${LAUNCHER_APP_PATH}/Contents/Resources/applet.icns"
    # osacompile also ships the default applet icon in an asset catalog, which
    # macOS prefers over applet.icns while CFBundleIconName points at it
    rm -f "${LAUNCHER_APP_PATH}/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "${LAUNCHER_APP_PATH}/Contents/Info.plist"
fi

# Editing the bundle invalidates the applet's signature, so re-sign it ad hoc
codesign --force --sign - "${LAUNCHER_APP_PATH}"

echo "✅ Built ${LAUNCHER_APP_PATH}"
echo "   Runs: ${LAUNCH_SCRIPT_PATH}"
echo "   Logs: ~/Library/Logs/Clicky/"
