#!/usr/bin/env bash

# Claude Code hook for tmux-agent-status
# Updates tmux session and pane status files based on Claude's working state

STATUS_DIR="$HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"
REFRESH_FILE="$STATUS_DIR/.sidebar-refresh"
mkdir -p "$STATUS_DIR" "$WAIT_DIR" "$PARKED_DIR" "$PANE_DIR"
[ -f "$REFRESH_FILE" ] || : > "$REFRESH_FILE"

# Read JSON from stdin (required by Claude Code hooks). The Stop payload
# carries a `background_tasks` array that we inspect below.
HOOK_JSON="$(cat 2>/dev/null || true)"

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
        echo "claude" > "$agent_file"

        session_status="done"
        local existing_pane_file=""
        for existing_pane_file in "$PANE_DIR/${tmux_session}_"*.status; do
            [ -f "$existing_pane_file" ] || continue

            local pane_status=""
            pane_status=$(cat "$existing_pane_file" 2>/dev/null || echo "")
            case "$pane_status" in
                working)
                    session_status="working"
                    break
                    ;;
                wait)
                    if [ "$session_status" != "working" ]; then
                        session_status="wait"
                    fi
                    ;;
                ask)
                    # ask outranks done but yields to working/wait.
                    case "$session_status" in
                        working|wait) ;;
                        *) session_status="ask" ;;
                    esac
                    ;;
            esac
        done
    fi

    echo "$session_status" > "$status_file"
    if in_remote_session; then
        echo "$session_status" > "$remote_status_file" 2>/dev/null
    fi
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

# Returns 0 if the Claude Code Stop payload reports a background task that is
# still running (e.g. a `run_in_background` Bash command). When the agent ends
# its turn while a background task keeps working, it isn't really idle, so we
# keep it "working" instead of flipping to "done". Claude re-invokes the agent
# when the task finishes, firing another Stop with an empty (or all-finished)
# background_tasks array, which then marks the session done.
#
# Older Claude versions omit the field entirely; that yields no match and the
# Stop is treated as done, matching the previous behaviour.
has_running_background_task() {
    local json="$1"
    [ -n "$json" ] || return 1

    if command -v jq >/dev/null 2>&1; then
        local count
        count="$(printf '%s' "$json" | \
            jq -r '[.background_tasks[]? | select(.status == "running")] | length' \
            2>/dev/null)"
        [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null
        return
    fi

    # Fallback without jq: an empty array is "background_tasks":[] and is
    # rejected first; otherwise look for a running task in a populated array.
    case "$json" in
        *'"background_tasks":[]'*) return 1 ;;
        *'"background_tasks":['*'"status":"running"'*) return 0 ;;
        *) return 1 ;;
    esac
}

TMUX_SESSION=$(get_tmux_session) || exit 0
HOOK_TYPE="${1:-}"
WAIT_FILE="$WAIT_DIR/${TMUX_SESSION}.wait"
PARKED_FILE="$PARKED_DIR/${TMUX_SESSION}.parked"

case "$HOOK_TYPE" in
    UserPromptSubmit)
        # User submitted a prompt — this is an explicit interaction, so
        # cancel wait mode and unpark.
        clear_interaction_overrides "$TMUX_SESSION"
        set_status "$TMUX_SESSION" "working"
        mark_refresh
        ;;
    PreToolUse)
        # Agent is calling a tool — mark working but do NOT unpark.
        # Parking is an explicit user decision; only user interaction
        # (UserPromptSubmit) should unpark.
        rm -f "$WAIT_FILE"
        if [ ! -f "$PARKED_FILE" ]; then
            set_status "$TMUX_SESSION" "working"
        fi
        mark_refresh
        ;;
    Stop)
        # Claude has finished responding (SubagentStop excluded - subagents
        # finishing doesn't mean the main agent is done). If the turn ended
        # while a background task is still running, the agent isn't idle yet —
        # keep it working until a later Stop reports the task finished.
        if has_running_background_task "$HOOK_JSON"; then
            set_status "$TMUX_SESSION" "working"
        else
            set_status "$TMUX_SESSION" "done"
        fi
        mark_refresh
        ;;
    Notification)
        # Notification fires for two distinct cases, distinguished by .message:
        #   1. A permission prompt or question Claude is blocked on
        #      ("Claude needs your permission to use ...") -> "ask".
        #   2. The prompt sat idle for 60s with nothing pending
        #      ("Claude is waiting for your input") -> not a question, so keep
        #      it "done". Mapping this to "ask" left sessions stuck on "ask".
        notif_msg=""
        if command -v jq >/dev/null 2>&1; then
            notif_msg="$(printf '%s' "$HOOK_JSON" | jq -r '.message // ""' 2>/dev/null)"
        else
            notif_msg="$HOOK_JSON"
        fi

        case "$notif_msg" in
            *"waiting for your input"*)
                # Idle timeout — nothing actually pending.
                set_status "$TMUX_SESSION" "done"
                ;;
            *)
                set_status "$TMUX_SESSION" "ask"
                SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                "$SCRIPT_DIR/../scripts/play-sound.sh" ask 2>/dev/null &
                ;;
        esac
        mark_refresh
        ;;
esac

# Always exit successfully
exit 0
