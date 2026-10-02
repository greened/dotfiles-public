# shellcheck shell=bash
# tmux-powerline theme for these dotfiles, written against tmux-powerline v3.2.0.
# The plugin sources this file on every status refresh, so it runs no commands.
#
# The glyphs are literal UTF-8 because the macOS /bin/bash cannot read $'\u'
# escapes. Every one is a single cell: the powerline arrows (U+E0B0 to U+E0B3)
# and Font Awesome icons from the Nerd Fonts Private Use Area, which Emacs
# draws with Symbols Nerd Font Mono.

if tp_patched_font_in_use; then
	TMUX_POWERLINE_SEPARATOR_LEFT_BOLD=""
	TMUX_POWERLINE_SEPARATOR_LEFT_THIN=""
	TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD=""
	TMUX_POWERLINE_SEPARATOR_RIGHT_THIN=""
	theme_active_marker=""
	theme_zoom_marker=""
	theme_bell_marker=""
else
	TMUX_POWERLINE_SEPARATOR_LEFT_BOLD="<"
	TMUX_POWERLINE_SEPARATOR_LEFT_THIN="|"
	TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD=">"
	TMUX_POWERLINE_SEPARATOR_RIGHT_THIN="|"
	theme_active_marker="*"
	theme_zoom_marker="Z"
	theme_bell_marker="!"
fi

# 256-colour codes, to match default-terminal "screen-256color" in tmux.conf.
TMUX_POWERLINE_DEFAULT_BACKGROUND_COLOR="235"
TMUX_POWERLINE_DEFAULT_FOREGROUND_COLOR="250"
TMUX_POWERLINE_DEFAULT_LEFTSIDE_SEPARATOR="$TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD"
TMUX_POWERLINE_DEFAULT_RIGHTSIDE_SEPARATOR="$TMUX_POWERLINE_SEPARATOR_LEFT_BOLD"

theme_bar_bg="colour235"
theme_current_bg="colour39"
theme_current_fg="colour232"
# tmux expands these per window when it draws the bar. A bell wins over
# activity. A window with no output since you last viewed it stays dim.
theme_window_bg="#{?window_bell_flag,colour160,#{?window_activity_flag,colour136,colour238}}"
theme_window_fg="#{?window_bell_flag,colour231,#{?window_activity_flag,colour232,colour245}}"

# Each window is a pill: a solid arrow cut into the bar, the index and name
# split by a thin separator, and a solid arrow back out.
TMUX_POWERLINE_WINDOW_STATUS_CURRENT=(
	"#[fg=${theme_bar_bg},bg=${theme_current_bg},nobold]"
	"$TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD"
	"#[fg=${theme_current_fg},bg=${theme_current_bg},bold]"
	" ${theme_active_marker} #I $TMUX_POWERLINE_SEPARATOR_RIGHT_THIN #W"
	"#{?window_zoomed_flag, ${theme_zoom_marker},} "
	"#[fg=${theme_current_bg},bg=${theme_bar_bg},nobold]"
	"$TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD"
)

TMUX_POWERLINE_WINDOW_STATUS_FORMAT=(
	"#[fg=${theme_bar_bg},bg=${theme_window_bg},nobold]"
	"$TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD"
	"#[fg=${theme_window_fg},bg=${theme_window_bg}]"
	" #I $TMUX_POWERLINE_SEPARATOR_RIGHT_THIN #W"
	"#{?window_zoomed_flag, ${theme_zoom_marker},}"
	"#{?window_bell_flag, ${theme_bell_marker},} "
	"#[fg=${theme_window_bg},bg=${theme_bar_bg}]"
	"$TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD"
)

# Segment format: name bg fg [separator] [separator_bg] [separator_fg].
# Only segments that print a tmux format or call date(1), because the bar
# redraws every second. The icons and formats live in config.sh.
TMUX_POWERLINE_LEFT_STATUS_SEGMENTS=(
	"tmux_session_info 148 234"
)

TMUX_POWERLINE_RIGHT_STATUS_SEGMENTS=(
	"date 238 250"
	"time 238 231 ${TMUX_POWERLINE_SEPARATOR_LEFT_THIN} no_sep_bg_color 244"
	"hostname 61 231"
)
