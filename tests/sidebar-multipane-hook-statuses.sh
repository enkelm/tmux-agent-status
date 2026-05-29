#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
PENDING_TOOL_DIR="$STATUS_DIR/pending-tool"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR" "$PENDING_TOOL_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-sessions)
        exit 0
        ;;
    list-panes)
        case "${2:-}" in
            -a)
                cat <<'OUT'
codex-multipane	%0	/home/test/project	100	0	main
codex-multipane	%4	/home/test/project	400	0	main
OUT
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    capture-pane)
        case "${*}" in
            *"%0"*)
                cat <<'OUT'
• Running sandboxed command

Allow Codex to run `touch /tmp/codex-test.txt`?
OUT
                ;;
            *"%4"*)
                echo "plain working output"
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN/pgrep"

cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
    "-eo pid=,ppid=")
        cat <<'OUT'
100 1 -zsh
400 1 -zsh
OUT
        ;;
    "-eo pid=,command=")
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/ps"

assert_contains() {
    local pattern="$1"
    local file="$2"
    local message="$3"

    if ! grep -Fq "$pattern" "$file"; then
        echo "Assertion failed: $message" >&2
        echo "Missing pattern: $pattern" >&2
        echo "In file: $file" >&2
        sed -n '1,120p' "$file" >&2
        exit 1
    fi
}

echo "working" > "$PANE_DIR/codex-multipane_%0.status"
echo "done" > "$PANE_DIR/codex-multipane_%4.status"
echo "codex" > "$PANE_DIR/codex-multipane_%0.agent"
echo "codex" > "$PANE_DIR/codex-multipane_%4.agent"
: > "$PENDING_TOOL_DIR/codex-multipane_%0.pending"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
"$REPO_DIR/scripts/sidebar-collector.sh" --once >/dev/null

CACHE_FILE="$STATUS_DIR/.sidebar-cache"
assert_contains $'PC:codex-multipane:0:1:0:1' "$CACHE_FILE" "multi-pane counts should include ask and done hook-tracked panes"
assert_contains $'R:S|codex-multipane|ask||\tcodex-multipane\tS' "$CACHE_FILE" "session row should show ask when a pending Codex pane has an approval prompt"
assert_contains $'R:P|codex-multipane|%0|codex|ask|' "$CACHE_FILE" "pending Codex pane with an approval prompt should appear as asking"
assert_contains $'R:P|codex-multipane|%4|codex|done|' "$CACHE_FILE" "done pane should appear as a child sidebar row"

echo "working" > "$PANE_DIR/codex-multipane_%4.status"
: > "$PENDING_TOOL_DIR/codex-multipane_%4.pending"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
"$REPO_DIR/scripts/sidebar-collector.sh" --once >/dev/null

assert_contains $'R:P|codex-multipane|%4|codex|working|' "$CACHE_FILE" "pending Codex pane without approval prompt should remain working"

touch -t 200001010000 "$PENDING_TOOL_DIR/codex-multipane_%4.pending"

PATH="$FAKE_BIN:$PATH" \
HOME="$TEST_HOME" \
"$REPO_DIR/scripts/sidebar-collector.sh" --once >/dev/null

assert_contains $'R:P|codex-multipane|%4|codex|ask|' "$CACHE_FILE" "stale pending Codex pane without visible prompt should fall back to asking"

echo "sidebar multi-pane hook status regression checks passed"
