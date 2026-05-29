#!/usr/bin/env bash

[[ -n "${_STATUS_SUMMARY_LOADED:-}" ]] && return 0
_STATUS_SUMMARY_LOADED=1

# nf-fa-question (U+F128). Defined via $'' so the PUA byte sequence survives
# any tool that strips raw glyphs from this file.
ASK_ICON=$''

format_working_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=yellow,bold]⚡ agent working#[default]"
    else
        echo "#[fg=yellow,bold]⚡ $count working#[default]"
    fi
}

format_waiting_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=cyan,bold]⏸ 1 waiting#[default]"
    else
        echo "#[fg=cyan,bold]⏸ $count waiting#[default]"
    fi
}

format_done_segment() {
    local count="$1"
    echo "#[fg=green]✓ $count done#[default]"
}

render_status_summary() {
    local working="$1"
    local waiting="$2"
    local done="$3"
    local total_agents="$4"
    local segments=()

    if [ "$total_agents" -eq 0 ]; then
        echo ""
    elif [ "$working" -eq 0 ] && [ "$waiting" -eq 0 ] && [ "$done" -gt 0 ]; then
        echo "#[fg=green,bold]✓ All agents ready#[default]"
    else
        [ "$working" -gt 0 ] && segments+=("$(format_working_segment "$working")")
        [ "$waiting" -gt 0 ] && segments+=("$(format_waiting_segment "$waiting")")
        [ "$done" -gt 0 ] && segments+=("$(format_done_segment "$done")")
        printf '%s\n' "${segments[*]}"
    fi
}

write_status_summary_cache() {
    local working="$1"
    local waiting="$2"
    local done="$3"
    local total_agents="$4"
    local ask="${5:-0}"
    local summary

    summary="$(render_status_summary "$working" "$waiting" "$done" "$total_agents")"
    printf '%s\n' "$working:$waiting:$done:$ask:$total_agents" > "${STATUS_LINE_COUNTS_FILE}.tmp"
    mv -f "${STATUS_LINE_COUNTS_FILE}.tmp" "$STATUS_LINE_COUNTS_FILE"
    printf '%s\n' "$summary" > "${STATUS_LINE_CACHE_FILE}.tmp"
    mv -f "${STATUS_LINE_CACHE_FILE}.tmp" "$STATUS_LINE_CACHE_FILE"

    write_agents_tmux_options "$working" "$waiting" "$done" "$total_agents" "$ask"
}

# Publish aggregate state to tmux user options so the catppuccin
# `@catppuccin_status_agents` pill can render without forking.
#
# Precedence: ask > done > wait > working > idle.
# Color is resolved from the active catppuccin flavor via @thm_* options,
# so theme swaps just work — re-reading them on every tick costs nothing.
write_agents_tmux_options() {
    local working="$1"
    local waiting="$2"
    local done_count="$3"
    local total="$4"
    local ask="${5:-0}"

    local state color_var color
    if (( ask > 0 )); then
        state="ask"; color_var="@thm_maroon"
    elif (( done_count > 0 )); then
        state="done"; color_var="@thm_peach"
    elif (( waiting > 0 )); then
        state="wait"; color_var="@thm_yellow"
    elif (( working > 0 )); then
        state="working"; color_var="@thm_mauve"
    else
        state="idle"; color_var="@thm_mauve"
    fi

    color=$(tmux show-option -gqv "$color_var" 2>/dev/null)
    [ -z "$color" ] && color="default"

    # Glyph-prefixed counts, zeros hidden. Single space between segments.
    local counts="" sep=""
    if (( working > 0 ))    ; then counts+="${sep}⚡${working}";    sep=" "; fi
    if (( waiting > 0 ))    ; then counts+="${sep}⏸${waiting}";    sep=" "; fi
    if (( done_count > 0 )) ; then counts+="${sep}✓${done_count}"; sep=" "; fi
    if (( ask > 0 ))        ; then counts+="${sep}${ASK_ICON}${ask}";       sep=" "; fi

    tmux set-option -gq "@agents_total" "$total" 2>/dev/null
    tmux set-option -gq "@agents_state" "$state" 2>/dev/null
    tmux set-option -gq "@agents_counts" "$counts" 2>/dev/null
    tmux set-option -gq "@agents_icon_bg" "$color" 2>/dev/null
}
