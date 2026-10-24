#!/bin/bash
set -uo pipefail

# =============================================================================
# start-clicky-with-local-worker.sh — Runs the Cloudflare Worker locally, then
# opens Clicky
#
# For builds whose CLICKY_WORKER_BASE_URL points at `wrangler dev`
# (http://localhost:8787). The script:
#   1. Starts `npx wrangler dev` in worker/ unless something is already
#      listening on the port, and waits until the worker accepts connections
#   2. Opens Clicky by bundle identifier, so any copy of the app works
#   3. If this script started the worker, stops it again after Clicky quits
#
# The worker reads its API keys from worker/.dev.vars, as `npx wrangler dev`
# always does.
#
# Usage:
#   ./scripts/start-clicky-with-local-worker.sh
#
# The "Clicky Launcher" app built by build-clicky-launcher-app.sh runs this.
# Worker output goes to ~/Library/Logs/Clicky/wrangler-dev.log.
# =============================================================================

# Apps launched from Finder get a minimal PATH, so add Homebrew's bin
# directory, where npx and node live
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKER_DIR="${PROJECT_DIR}/worker"
WORKER_PORT=8787
CLICKY_BUNDLE_IDENTIFIER="com.ptim.leanring-buddy"
CLICKY_PROCESS_NAME="Clicky"
WORKER_LOG_DIR="${HOME}/Library/Logs/Clicky"
WORKER_LOG_FILE="${WORKER_LOG_DIR}/wrangler-dev.log"
SECONDS_TO_WAIT_FOR_WORKER_TO_START=60
SECONDS_TO_WAIT_FOR_CLICKY_TO_START=15

show_error_alert() {
    local error_message="$1"
    echo "❌ ${error_message}" >&2
    osascript -e "display alert \"Clicky Launcher\" message \"${error_message}\" as critical" >/dev/null 2>&1
}

is_worker_port_listening() {
    lsof -nP -iTCP:${WORKER_PORT} -sTCP:LISTEN >/dev/null 2>&1
}

is_clicky_running() {
    pgrep -x "${CLICKY_PROCESS_NAME}" >/dev/null 2>&1
}

# ── Start the worker ─────────────────────────────────────────────────────────

worker_process_group_id=""

if is_worker_port_listening; then
    echo "Something is already listening on port ${WORKER_PORT}; using it as the worker."
else
    if ! command -v npx >/dev/null 2>&1; then
        show_error_alert "npx was not found. Install Node.js (brew install node) to run the worker locally."
        exit 1
    fi

    mkdir -p "${WORKER_LOG_DIR}"
    echo "Starting wrangler dev in ${WORKER_DIR} (log: ${WORKER_LOG_FILE})"

    # Job control puts the background job in its own process group, so the
    # whole tree (npx → wrangler → workerd) can be stopped together later.
    # This is why the script uses bash: zsh refuses `set -m` without a terminal.
    set -m
    (cd "${WORKER_DIR}" && exec npx wrangler dev --port ${WORKER_PORT} --show-interactive-dev-session=false) \
        >"${WORKER_LOG_FILE}" 2>&1 </dev/null &
    worker_process_group_id=$!
    set +m

    seconds_waited_for_worker=0
    until is_worker_port_listening; do
        if ! kill -0 "${worker_process_group_id}" 2>/dev/null; then
            show_error_alert "wrangler dev exited before the worker started. See ${WORKER_LOG_FILE}"
            exit 1
        fi
        if (( seconds_waited_for_worker >= SECONDS_TO_WAIT_FOR_WORKER_TO_START )); then
            kill -- "-${worker_process_group_id}" 2>/dev/null
            show_error_alert "The worker did not start within ${SECONDS_TO_WAIT_FOR_WORKER_TO_START} seconds. See ${WORKER_LOG_FILE}"
            exit 1
        fi
        sleep 1
        (( seconds_waited_for_worker++ ))
    done
    echo "Worker is listening on port ${WORKER_PORT}."
fi

# ── Open Clicky ──────────────────────────────────────────────────────────────

if ! open -b "${CLICKY_BUNDLE_IDENTIFIER}"; then
    [[ -n "${worker_process_group_id}" ]] && kill -- "-${worker_process_group_id}" 2>/dev/null
    show_error_alert "Could not open Clicky (${CLICKY_BUNDLE_IDENTIFIER}). Build it in Xcode and copy it to /Applications first."
    exit 1
fi

# ── Stop the worker when Clicky quits ────────────────────────────────────────
# Only a worker this script started is stopped; one that was already running
# belongs to someone else (for example a `wrangler dev` in a terminal).

if [[ -z "${worker_process_group_id}" ]]; then
    exit 0
fi

seconds_waited_for_clicky=0
until is_clicky_running; do
    if (( seconds_waited_for_clicky >= SECONDS_TO_WAIT_FOR_CLICKY_TO_START )); then
        break
    fi
    sleep 1
    (( seconds_waited_for_clicky++ ))
done

while is_clicky_running; do
    sleep 5
done

echo "Clicky quit; stopping the worker."
kill -- "-${worker_process_group_id}" 2>/dev/null
exit 0
