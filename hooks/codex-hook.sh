#!/usr/bin/env bash

# Codex hook for tmux-agent-status.
# Hook events are passed as the first argument by the configured Codex command
# hook. The JSON payload is read from stdin so PreToolUse/PostToolUse can track
# pending tool calls for approval-prompt detection.

STATUS_DIR="$HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"
PENDING_TOOL_DIR="$STATUS_DIR/pending-tool"
REFRESH_FILE="$STATUS_DIR/.sidebar-refresh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$STATUS_DIR" "$WAIT_DIR" "$PARKED_DIR" "$PANE_DIR" "$PENDING_TOOL_DIR"
[ -f "$REFRESH_FILE" ] || : > "$REFRESH_FILE"

# Read the JSON payload from stdin. Codex sends it on PreToolUse/PostToolUse and
# we use tool_use_id to track per-call pending-tool flags (consumed by the
# poll-side scrape that promotes "working" → "ask" when codex shows an approval
# dialog). Other events ignore the payload.
HOOK_PAYLOAD=$(cat 2>/dev/null || true)

in_remote_session() {
    [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]
}

get_tmux_session() {
    local tmux_session=""

    if [ -n "${TMUX:-}" ] || in_remote_session; then
        tmux_session=$(tmux display-message -p '#{session_name}' 2>/dev/null)

        if [ -z "$tmux_session" ]; then
            if in_remote_session; then
                case "$(hostname -s 2>/dev/null)" in
                    instance-*) tmux_session="reachgpu" ;;
                    keen-schrodinger) tmux_session="sd1" ;;
                    sam-l4-workstation-image) tmux_session="l4-workstation" ;;
                    persistent-faraday) tmux_session="tig" ;;
                    instance-20250620-122051) tmux_session="reachgpu" ;;
                    *) tmux_session=$(hostname -s 2>/dev/null) ;;
                esac
            elif [ -n "${TMUX:-}" ]; then
                local socket_path="${TMUX%%,*}"
                tmux_session=$(basename "$socket_path")
            fi
        fi
    fi

    [ -n "$tmux_session" ] || return 1
    printf '%s\n' "$tmux_session"
}

set_status() {
    local tmux_session="$1"
    local requested_status="$2"
    local session_status="$requested_status"
    local status_file="$STATUS_DIR/${tmux_session}.status"
    local remote_status_file="$STATUS_DIR/${tmux_session}-remote.status"

    if [ -n "${TMUX_PANE:-}" ]; then
        local pane_file="$PANE_DIR/${tmux_session}_${TMUX_PANE}.status"
        local agent_file="$PANE_DIR/${tmux_session}_${TMUX_PANE}.agent"
        echo "$requested_status" > "$pane_file"
        echo "codex" > "$agent_file"

        session_status="done"
        local existing_pane_file=""
        for existing_pane_file in "$PANE_DIR/${tmux_session}_"*.status; do
            [ -f "$existing_pane_file" ] || continue

            local pane_status=""
            pane_status=$(cat "$existing_pane_file" 2>/dev/null || echo "")
            case "$pane_status" in
                ask)
                    session_status="ask"
                    break
                    ;;
                working)
                    if [ "$session_status" != "ask" ]; then
                        session_status="working"
                    fi
                    ;;
                wait)
                    if [ "$session_status" != "ask" ] && [ "$session_status" != "working" ]; then
                        session_status="wait"
                    fi
                    ;;
            esac
        done
    fi

    echo "$session_status" > "$status_file"
    if in_remote_session; then
        echo "$session_status" > "$remote_status_file" 2>/dev/null
    fi
}

pending_file_for_pane() {
    local tmux_session="$1"
    [ -n "${TMUX_PANE:-}" ] || return 1
    printf '%s\n' "$PENDING_TOOL_DIR/${tmux_session}_${TMUX_PANE}.pending"
}

write_pending_tool() {
    local tmux_session="$1"
    local pending_file
    pending_file=$(pending_file_for_pane "$tmux_session") || return 0
    local tool_use_id=""
    if [ -n "$HOOK_PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
        tool_use_id=$(printf '%s' "$HOOK_PAYLOAD" | jq -r '.tool_use_id // empty' 2>/dev/null)
    fi
    printf '%s\n' "${tool_use_id:-unknown}" > "$pending_file"
}

payload_requests_user_choice() {
    [ -n "$HOOK_PAYLOAD" ] || return 1

    # Harness-level prompts are not always rendered inside the tmux pane. Treat
    # tools that explicitly request a user decision as ask immediately.
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$HOOK_PAYLOAD" | jq -e '
            tostring
            | test("request_user_input|sandbox_permissions[[:space:]]*\\\\?\"?[[:space:]]*:[[:space:]]*\\\\?\"require_escalated|require_escalated")
        ' >/dev/null 2>&1 && return 0
    fi

    printf '%s' "$HOOK_PAYLOAD" | grep -qE 'request_user_input|sandbox_permissions[^[:space:]]*require_escalated|require_escalated'
}

pending_ask_after_seconds() {
    local fallback_after
    fallback_after=$(tmux show-option -gqv @agent-codex-pending-ask-seconds 2>/dev/null || true)
    case "$fallback_after" in
        ''|*[!0-9]*) fallback_after=1 ;;
    esac
    printf '%s\n' "$fallback_after"
}

schedule_pending_ask_fallback() {
    local tmux_session="$1"
    local pending_file
    pending_file=$(pending_file_for_pane "$tmux_session") || return 0

    local fallback_after
    fallback_after=$(pending_ask_after_seconds)
    (( fallback_after > 0 )) || return 0

    local expected_tool_use_id=""
    expected_tool_use_id=$(cat "$pending_file" 2>/dev/null || echo "")
    local pane="${TMUX_PANE:-}"
    local status_dir="$STATUS_DIR"
    local pane_dir="$PANE_DIR"
    local refresh_file="$REFRESH_FILE"
    local script_dir="$SCRIPT_DIR"

    (
        sleep "$fallback_after"
        [ -n "$pane" ] || exit 0
        [ -f "$pending_file" ] || exit 0
        [ "$(cat "$pending_file" 2>/dev/null || echo "")" = "$expected_tool_use_id" ] || exit 0

        local previous_pane_status=""
        previous_pane_status=$(cat "$pane_dir/${tmux_session}_${pane}.status" 2>/dev/null || echo "")
        echo "ask" > "$pane_dir/${tmux_session}_${pane}.status" 2>/dev/null || exit 0
        echo "codex" > "$pane_dir/${tmux_session}_${pane}.agent" 2>/dev/null || true

        local session_status="done"
        local existing_pane_file pane_status
        for existing_pane_file in "$pane_dir/${tmux_session}_"*.status; do
            [ -f "$existing_pane_file" ] || continue
            pane_status=$(cat "$existing_pane_file" 2>/dev/null || echo "")
            case "$pane_status" in
                ask)
                    session_status="ask"
                    break
                    ;;
                working)
                    if [ "$session_status" != "ask" ]; then
                        session_status="working"
                    fi
                    ;;
                wait)
                    if [ "$session_status" != "ask" ] && [ "$session_status" != "working" ]; then
                        session_status="wait"
                    fi
                    ;;
            esac
        done
        echo "$session_status" > "$status_dir/${tmux_session}.status" 2>/dev/null || true
        touch "$refresh_file" 2>/dev/null || true
        if [ "$previous_pane_status" != "ask" ]; then
            "$script_dir/../scripts/play-sound.sh" ask 2>/dev/null &
        fi
    ) >/dev/null 2>&1 &
}

clear_pending_tool() {
    local tmux_session="$1"
    [ -n "${TMUX_PANE:-}" ] || return 0
    rm -f "$PENDING_TOOL_DIR/${tmux_session}_${TMUX_PANE}.pending" 2>/dev/null || true
}

clear_interaction_overrides() {
    local tmux_session="$1"
    local session_wait_file="$WAIT_DIR/${tmux_session}.wait"
    local session_parked_file="$PARKED_DIR/${tmux_session}.parked"

    if [ -f "$session_wait_file" ]; then
        rm -f "$session_wait_file" "$WAIT_DIR/${tmux_session}_"*.wait 2>/dev/null
    elif [ -n "${TMUX_PANE:-}" ]; then
        rm -f "$WAIT_DIR/${tmux_session}_${TMUX_PANE}.wait"
    fi

    if [ -f "$session_parked_file" ]; then
        rm -f "$session_parked_file" "$PARKED_DIR/${tmux_session}_"*.parked 2>/dev/null
    elif [ -n "${TMUX_PANE:-}" ]; then
        rm -f "$PARKED_DIR/${tmux_session}_${TMUX_PANE}.parked"
    fi
}

mark_refresh() {
    touch "$REFRESH_FILE" 2>/dev/null || true
}

play_ask_sound() {
    "$SCRIPT_DIR/../scripts/play-sound.sh" ask 2>/dev/null &
}

TMUX_SESSION=$(get_tmux_session) || exit 0
HOOK_TYPE="${1:-}"
WAIT_FILE="$WAIT_DIR/${TMUX_SESSION}.wait"
PARKED_FILE="$PARKED_DIR/${TMUX_SESSION}.parked"

case "$HOOK_TYPE" in
    SessionStart)
        clear_pending_tool "$TMUX_SESSION"
        if [ ! -f "$WAIT_FILE" ] && [ ! -f "$PARKED_FILE" ]; then
            set_status "$TMUX_SESSION" "done"
            mark_refresh
        fi
        ;;
    UserPromptSubmit)
        clear_interaction_overrides "$TMUX_SESSION"
        clear_pending_tool "$TMUX_SESSION"
        set_status "$TMUX_SESSION" "working"
        mark_refresh
        ;;
    PreToolUse)
        rm -f "$WAIT_FILE"
        write_pending_tool "$TMUX_SESSION"
        if [ ! -f "$PARKED_FILE" ]; then
            if payload_requests_user_choice; then
                previous_pane_status=$(cat "$PANE_DIR/${TMUX_SESSION}_${TMUX_PANE}.status" 2>/dev/null || echo "")
                set_status "$TMUX_SESSION" "ask"
                [ "$previous_pane_status" = "ask" ] || play_ask_sound
            else
                set_status "$TMUX_SESSION" "working"
                schedule_pending_ask_fallback "$TMUX_SESSION"
            fi
        fi
        mark_refresh
        ;;
    PostToolUse)
        rm -f "$WAIT_FILE"
        clear_pending_tool "$TMUX_SESSION"
        if [ ! -f "$PARKED_FILE" ]; then
            set_status "$TMUX_SESSION" "working"
        fi
        mark_refresh
        ;;
    Stop)
        clear_pending_tool "$TMUX_SESSION"
        set_status "$TMUX_SESSION" "done"
        mark_refresh
        ;;
esac

exit 0
