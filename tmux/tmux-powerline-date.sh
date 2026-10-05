# shellcheck shell=bash
# Replaces tmux-powerline's date segment so the date uses the same zone as
# the time. Without it, near midnight the bar shows the host's day.

TMUX_POWERLINE_SEG_DATE_FORMAT="${TMUX_POWERLINE_SEG_DATE_FORMAT:-%F}"

run_segment() {
	if [ -n "$TMUX_POWERLINE_SEG_TIME_TZ" ]; then
		TZ="$TMUX_POWERLINE_SEG_TIME_TZ" date +"$TMUX_POWERLINE_SEG_DATE_FORMAT"
	else
		date +"$TMUX_POWERLINE_SEG_DATE_FORMAT"
	fi
	return 0
}
