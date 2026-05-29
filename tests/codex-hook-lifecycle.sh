#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"
PENDING_TOOL_DIR="$STATUS_DIR/pending-tool"
REFRESH_FILE="$STATUS_DIR/.sidebar-refresh"
SOUND_LOG="$TMP_DIR/sound.log"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$WAIT_DIR" "$PARKED_DIR" "$PANE_DIR" "$PENDING_TOOL_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    display-message)
        if [ "${2:-}" = "-p" ] && [ "${3:-}" = "#{session_name}" ]; then
            echo "codex-hooks"
            exit 0
        fi
        ;;
    show-option)
        if [ "${2:-}" = "-gqv" ] && [ "${3:-}" = "@agent-codex-pending-ask-seconds" ]; then
            echo "1"
            exit 0
        fi
        ;;
esac

exit 1
EOF
chmod +x "$FAKE_BIN/tmux"

cat > "$FAKE_BIN/afplay" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "afplay $*" >> "${SOUND_LOG:?}"
EOF
chmod +x "$FAKE_BIN/afplay"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo "Assertion failed: $message" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

sound_count() {
    if [ -f "$SOUND_LOG" ]; then
        wc -l < "$SOUND_LOG" | tr -d ' '
    else
        echo 0
    fi
}

wait_for_sound_count() {
    local expected="$1"
    local i
    for i in {1..20}; do
        if [ "$(sound_count)" -ge "$expected" ]; then
            return 0
        fi
        sleep 0.1
    done
    echo "Assertion failed: expected at least $expected ask sounds, got $(sound_count)" >&2
    [ -f "$SOUND_LOG" ] && cat "$SOUND_LOG" >&2
    exit 1
}

run_hook() {
    local hook_name="$1"
    local payload="${2:-{\"hook_event_name\":\"$hook_name\"}}"

    printf '%s\n' "$payload" | \
        PATH="$FAKE_BIN:$PATH" \
        HOME="$TEST_HOME" \
        SOUND_LOG="$SOUND_LOG" \
        TMUX="/tmp/tmux-test,4242,0" \
        TMUX_PANE="%9" \
        "$REPO_DIR/hooks/codex-hook.sh" "$hook_name"
}

run_hook "SessionStart"
session_status="$(cat "$STATUS_DIR/codex-hooks.status")"
pane_status="$(cat "$PANE_DIR/codex-hooks_%9.status")"
agent_name="$(cat "$PANE_DIR/codex-hooks_%9.agent")"
assert_eq "done" "$session_status" "SessionStart should seed the session as done"
assert_eq "done" "$pane_status" "SessionStart should seed the pane as done"
assert_eq "codex" "$agent_name" "Codex hooks should persist the pane agent name"
[ -f "$REFRESH_FILE" ] || { echo "Assertion failed: SessionStart should touch sidebar refresh marker" >&2; exit 1; }
if [ -f "$PENDING_TOOL_DIR/codex-hooks_%9.pending" ]; then
    echo "Assertion failed: SessionStart should clear stale pending tool flags" >&2
    exit 1
fi

echo "wait" > "$STATUS_DIR/codex-hooks.status"
echo "wait" > "$PANE_DIR/codex-hooks_%9.status"
echo "1" > "$WAIT_DIR/codex-hooks.wait"
echo "1" > "$WAIT_DIR/codex-hooks_%9.wait"
echo "1" > "$WAIT_DIR/codex-hooks_%10.wait"
: > "$PARKED_DIR/codex-hooks.parked"
: > "$PARKED_DIR/codex-hooks_%9.parked"
: > "$PARKED_DIR/codex-hooks_%10.parked"
run_hook "UserPromptSubmit"
session_status="$(cat "$STATUS_DIR/codex-hooks.status")"
pane_status="$(cat "$PANE_DIR/codex-hooks_%9.status")"
assert_eq "working" "$session_status" "UserPromptSubmit should mark the session working"
assert_eq "working" "$pane_status" "UserPromptSubmit should mark the pane working"
[ -f "$REFRESH_FILE" ] || { echo "Assertion failed: UserPromptSubmit should leave a sidebar refresh marker" >&2; exit 1; }
if [ -f "$WAIT_DIR/codex-hooks.wait" ]; then
    echo "Assertion failed: UserPromptSubmit should clear wait mode" >&2
    exit 1
fi
if [ -f "$PARKED_DIR/codex-hooks.parked" ]; then
    echo "Assertion failed: UserPromptSubmit should unpark the session" >&2
    exit 1
fi
if [ -f "$WAIT_DIR/codex-hooks_%9.wait" ] || [ -f "$WAIT_DIR/codex-hooks_%10.wait" ]; then
    echo "Assertion failed: UserPromptSubmit should clear per-pane wait overrides when the whole session was waiting" >&2
    exit 1
fi
if [ -f "$PARKED_DIR/codex-hooks_%9.parked" ] || [ -f "$PARKED_DIR/codex-hooks_%10.parked" ]; then
    echo "Assertion failed: UserPromptSubmit should clear per-pane parked overrides when the whole session was parked" >&2
    exit 1
fi

echo "parked" > "$PANE_DIR/codex-hooks_%9.status"
echo "1" > "$WAIT_DIR/codex-hooks_%9.wait"
: > "$PARKED_DIR/codex-hooks_%9.parked"
run_hook "UserPromptSubmit"
if [ -f "$WAIT_DIR/codex-hooks_%9.wait" ]; then
    echo "Assertion failed: UserPromptSubmit should clear the current pane wait override" >&2
    exit 1
fi
if [ -f "$PARKED_DIR/codex-hooks_%9.parked" ]; then
    echo "Assertion failed: UserPromptSubmit should clear the current pane parked override" >&2
    exit 1
fi

echo "parked" > "$STATUS_DIR/codex-hooks.status"
rm -f "$PANE_DIR/codex-hooks_%9.status"
echo "1" > "$WAIT_DIR/codex-hooks.wait"
: > "$PARKED_DIR/codex-hooks.parked"
run_hook "PreToolUse"
session_status="$(cat "$STATUS_DIR/codex-hooks.status")"
assert_eq "parked" "$session_status" "PreToolUse should not unpark explicitly parked sessions"
assert_eq "unknown" "$(cat "$PENDING_TOOL_DIR/codex-hooks_%9.pending")" "PreToolUse should still track pending tools without tool_use_id"
if [ -f "$WAIT_DIR/codex-hooks.wait" ]; then
    echo "Assertion failed: PreToolUse should still clear wait mode" >&2
    exit 1
fi
if [ ! -f "$PARKED_DIR/codex-hooks.parked" ]; then
    echo "Assertion failed: PreToolUse should preserve the parked marker" >&2
    exit 1
fi

rm -f "$PARKED_DIR/codex-hooks.parked"
run_hook "PostToolUse"
if [ -f "$PENDING_TOOL_DIR/codex-hooks_%9.pending" ]; then
    echo "Assertion failed: PostToolUse should clear pending tool flags" >&2
    exit 1
fi

run_hook "PreToolUse" '{"hook_event_name":"PreToolUse","tool_use_id":"call_needs_approval","tool_name":"exec_command","tool_input":{"sandbox_permissions":"require_escalated"}}'
session_status="$(cat "$STATUS_DIR/codex-hooks.status")"
pane_status="$(cat "$PANE_DIR/codex-hooks_%9.status")"
assert_eq "ask" "$session_status" "PreToolUse for harness approval prompts should mark the session ask"
assert_eq "ask" "$pane_status" "PreToolUse for harness approval prompts should mark the pane ask"
wait_for_sound_count 1
run_hook "PostToolUse"

run_hook "PreToolUse" '{"hook_event_name":"PreToolUse","tool_use_id":"call_user_input","tool_name":"request_user_input","tool_input":{"questions":[]}}'
session_status="$(cat "$STATUS_DIR/codex-hooks.status")"
pane_status="$(cat "$PANE_DIR/codex-hooks_%9.status")"
assert_eq "ask" "$session_status" "PreToolUse for user choice tools should mark the session ask"
assert_eq "ask" "$pane_status" "PreToolUse for user choice tools should mark the pane ask"
wait_for_sound_count 2
run_hook "PostToolUse"

run_hook "PreToolUse" '{"hook_event_name":"PreToolUse","tool_use_id":"call_test"}'
assert_eq "call_test" "$(cat "$PENDING_TOOL_DIR/codex-hooks_%9.pending")" "PreToolUse should persist tool_use_id for pending scrape gating"
session_status="$(cat "$STATUS_DIR/codex-hooks.status")"
pane_status="$(cat "$PANE_DIR/codex-hooks_%9.status")"
assert_eq "working" "$session_status" "Ordinary PreToolUse should start as working"
assert_eq "working" "$pane_status" "Ordinary PreToolUse should start the pane as working"
sleep 2
session_status="$(cat "$STATUS_DIR/codex-hooks.status")"
pane_status="$(cat "$PANE_DIR/codex-hooks_%9.status")"
assert_eq "ask" "$session_status" "Pending PreToolUse should fall back to ask after the configured delay"
assert_eq "ask" "$pane_status" "Pending PreToolUse should mark the pane ask after the configured delay"
wait_for_sound_count 3
run_hook "Stop"
session_status="$(cat "$STATUS_DIR/codex-hooks.status")"
pane_status="$(cat "$PANE_DIR/codex-hooks_%9.status")"
assert_eq "done" "$session_status" "Stop should mark the session done"
assert_eq "done" "$pane_status" "Stop should mark the pane done"
if [ -f "$PENDING_TOOL_DIR/codex-hooks_%9.pending" ]; then
    echo "Assertion failed: Stop should clear pending tool flags for denied/cancelled tools" >&2
    exit 1
fi

echo "Codex hook lifecycle checks passed"
