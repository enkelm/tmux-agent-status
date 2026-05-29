#!/usr/bin/env bash

# Sanitization + truncation for pane_title display in the switcher and sidebar.
# v1: pane_title is the only source of agent identity (Claude Code writes it
# live via OSC 2). See handoff doc for full spec.

[[ -n "${_PANE_TITLE_LIB_LOADED:-}" ]] && return 0
_PANE_TITLE_LIB_LOADED=1

# Returns the sanitized title on stdout, or empty if the title carries no
# information beyond what the row already shows.
#
# Usage: sanitize_pane_title <title> <cwd_basename> <command>
sanitize_pane_title() {
    local title="$1"
    local cwd_base="$2"
    local cmd="$3"

    [[ -z "$title" ]] && return 0

    # Strip leading non-ASCII decoration (spinner braille U+28xx, ✳, ⏵, etc.)
    # plus any following whitespace. Claude Code rotates the spinner ~10×/sec;
    # stripping it makes the title stable across refreshes. Restricted to
    # non-ASCII so we don't accidentally chew through punctuation like "."
    # that's part of meaningful titles (e.g. ".dotfiles").
    while [[ -n "$title" ]]; do
        local first_byte
        printf -v first_byte '%d' "'${title:0:1}"
        (( first_byte >= 128 )) || break
        title="${title:1}"
        title="${title# }"
    done
    title="${title# }"
    title="${title% }"
    # Strip pipe so the title is safe to embed in pipe-delimited cache entries.
    title="${title//|/ }"

    [[ -z "$title" ]] && return 0

    # Drop if title is just the cwd basename, the command, or the hostname —
    # these add no information over the row's other columns. Default Codex
    # title is the cwd basename, so this also hides empty Codex labels.
    local host title_base
    host="${HOSTNAME:-$(hostname -s 2>/dev/null)}"
    host="${host%%.*}"
    title_base="${title%%.*}"
    if [[ "$title" == "$cwd_base" || "$title" == "$cmd" || "$title_base" == "$host" ]]; then
        return 0
    fi

    printf '%s' "$title"
}

# Truncate (byte-wise) with a trailing ellipsis if needed.
# Usage: truncate_title <title> <max_width>
truncate_title() {
    local title="$1"
    local max="$2"
    (( max <= 0 )) && return 0
    if (( ${#title} > max )); then
        printf '%s…' "${title:0:$((max - 1))}"
    else
        printf '%s' "$title"
    fi
}

cached_pane_title() {
    local session="$1"
    local pane_id="$2"
    local title_file="${PANE_TITLE_DIR:-$HOME/.cache/tmux-agent-status/pane-titles}/${session}_${pane_id}.title"

    [ -f "$title_file" ] || return 0
    sed -n '1p' "$title_file" 2>/dev/null | sed 's/|//g; s/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}
