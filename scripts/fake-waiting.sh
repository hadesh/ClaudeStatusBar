#!/usr/bin/env bash
# Fake a Claude Code session file to exercise the waiting-notification path
# end-to-end (initial transition + WaitingReminderTracker reminders).
#
# Usage:
#   ./scripts/fake-waiting.sh                   # 1 fake session, 150s waiting
#   ./scripts/fake-waiting.sh -d 60             # 60s waiting then resolves
#   ./scripts/fake-waiting.sh -n 2              # 2 sessions, staggered by 5s
#   ./scripts/fake-waiting.sh -d 60 -n 2
#
# Behaviour:
#   1. Writes status=busy first so SessionWatcher sees a non-waiting baseline.
#   2. After 2s flips to status=waiting — this is the busy→waiting edge that
#      WaitingTransitionDetector notifies on.
#   3. Holds waiting for the configured duration. With defaults (initialDelay=30,
#      interval=30, maxReminders=3), a 150s window lets you see the initial
#      notification + all 3 reminders.
#   4. Flips back to busy and cleans up the file (also on Ctrl-C / kill).
#
# The script's own PID is written into the JSON and stays alive throughout, so
# ProcessLiveness.isAlive(pid) keeps the fake session visible to the app.
set -euo pipefail

SESSIONS_DIR="$HOME/.claude/sessions"
DURATION=150
COUNT=1
STAGGER=5

while getopts "d:n:s:h" opt; do
  case "$opt" in
    d) DURATION="$OPTARG" ;;
    n) COUNT="$OPTARG" ;;
    s) STAGGER="$OPTARG" ;;
    h)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *) exit 2 ;;
  esac
done

mkdir -p "$SESSIONS_DIR"
CWD="$(pwd)"
CREATED_FILES=()

cleanup() {
  for f in "${CREATED_FILES[@]:-}"; do
    [ -n "$f" ] && rm -f "$f"
  done
  echo "[fake-waiting] cleaned up."
}
trap cleanup EXIT INT TERM

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

write_session() {
  local file="$1" pid="$2" status="$3"
  local ts; ts=$(now_ms)
  cat > "$file" <<EOF
{"pid":${pid},"sessionId":"fake-${pid}","cwd":"${CWD}","startedAt":${ts},"version":"fake","kind":"interactive","entrypoint":"cli","status":"${status}","waitingFor":"tool approval","updatedAt":${ts}}
EOF
}

# We need each fake session to have a distinct, live pid. Spawn a background
# `sleep` per session and use its pid as the fake session pid.
PIDS=()
for i in $(seq 1 "$COUNT"); do
  sleep $((DURATION + 30)) &
  pid=$!
  PIDS+=("$pid")
  file="$SESSIONS_DIR/${pid}.json"
  CREATED_FILES+=("$file")

  write_session "$file" "$pid" "busy"
  echo "[fake-waiting] session #${i} pid=${pid} → busy"

  if [ "$i" -lt "$COUNT" ]; then
    sleep "$STAGGER"
  fi
done

# Edge: busy → waiting. Without this delay the watcher may coalesce the two
# writes and miss the transition.
sleep 2
for idx in "${!PIDS[@]}"; do
  pid="${PIDS[$idx]}"
  write_session "$SESSIONS_DIR/${pid}.json" "$pid" "waiting"
  echo "[fake-waiting] session #$((idx+1)) pid=${pid} → waiting (expect notification within ~30s)"
done

echo "[fake-waiting] holding for ${DURATION}s — Ctrl-C to abort early."
sleep "$DURATION"

# Edge: waiting → busy so the reminder tracker drops state for these pids.
for pid in "${PIDS[@]}"; do
  write_session "$SESSIONS_DIR/${pid}.json" "$pid" "busy"
done
echo "[fake-waiting] flipped back to busy; sleeping 3s before cleanup so the watcher catches it."
sleep 3

# Kill the placeholder sleeps so cleanup's rm doesn't race them.
for pid in "${PIDS[@]}"; do
  kill "$pid" 2>/dev/null || true
done
