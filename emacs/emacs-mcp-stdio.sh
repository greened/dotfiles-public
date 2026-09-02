#!/usr/bin/env bash
# emacs-mcp-stdio.sh - Connect to Emacs MCP server via stdio transport
#
# Copyright (C) 2025 Laurynas Biveinis
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# ---------------------------------------------------------------------------
# VENDORED from mcp-server-lib.el, commit dec55e6
#   https://github.com/laurynas-biveinis/mcp-server-lib.el
#
# Why a copy lives here: the MCP clients run on the dev VM while Emacs runs on
# the Mac, so the VM needs this transport script even though the elisp package
# is installed only Mac-side.  It was previously an untracked hand-copy in
# ~/.local/bin -- invisible to git and lost on any reinstall.
#
# LOCAL DELTA vs upstream: `timeout 60' on the three emacsclient calls
# (INIT_CMD, the one in the read loop, and STOP_CMD).  Upstream has no timeout,
# so if Emacs stops servicing its server socket every request blocks forever.
# That happened on 2026-09-02: a dropped link left ssh subprocesses alive with
# CLOSED sockets, Emacs stayed blocked in wait_reading_process_output for 20+
# hours, and ~19 of these bridges piled up, none of them ever failing visibly.
# A timeout cannot live in elisp -- with the Lisp loop stalled, no timer fires.
#
# The script runs `set -eu -o pipefail', so a timeout exits the bridge instead
# of parking it, and the client sees the server go away.  That is the point.
#
# Re-syncing: diff against the installed package, apply upstream, re-add the
# three timeouts:
#   diff ~/.emacs.d/elpaca/sources/mcp-server-lib/emacs-mcp-stdio.sh \
#        ~/lib/dotfiles/emacs/emacs-mcp-stdio.sh
# Upstream issue proposing a configurable EMACS_MCP_TIMEOUT is pending; drop
# this delta once it lands.
# ---------------------------------------------------------------------------

set -eu -o pipefail

# Default values
INIT_FUNCTION=""
STOP_FUNCTION=""
SOCKET=""
SERVER_ID=""
EMACS_MCP_DEBUG_LOG=${EMACS_MCP_DEBUG_LOG:-""}

# Debug logging setup
if [ -n "$EMACS_MCP_DEBUG_LOG" ]; then
	# Verify log file is writable
	if ! touch "$EMACS_MCP_DEBUG_LOG" 2>/dev/null; then
		echo "Error: Cannot write to debug log file: $EMACS_MCP_DEBUG_LOG" >&2
		exit 1
	fi

	# Helper function for debug logging
	mcp_debug_log() {
		local direction="$1"
		local message="$2"
		local timestamp
		timestamp=$(date "+%Y-%m-%d %H:%M:%S")
		echo "[$timestamp] [$$] MCP-${direction}: ${message}" >>"$EMACS_MCP_DEBUG_LOG"
	}

	mcp_debug_log "INFO" "Debug logging enabled"
else
	# No-op function when debug logging is disabled
	mcp_debug_log() {
		:
	}
fi

# Parse command line arguments
while [ $# -gt 0 ]; do
	case "$1" in
	--init-function=*)
		INIT_FUNCTION="${1#--init-function=}"
		shift
		;;
	--stop-function=*)
		STOP_FUNCTION="${1#--stop-function=}"
		shift
		;;
	--socket=*)
		SOCKET="${1#--socket=}"
		shift
		;;
	--server-id=*)
		SERVER_ID="${1#--server-id=}"
		shift
		;;
	*)
		echo "Unknown option: $1" >&2
		echo "Usage: $0 [--init-function=name] [--stop-function=name] [--socket=path] [--server-id=id]" >&2
		exit 1
		;;
	esac
done

# Set socket arguments if provided
if [ -n "$SOCKET" ]; then
	readonly SOCKET_OPTIONS=("-s" "$SOCKET")
	mcp_debug_log "INFO" "Using socket: $SOCKET"
else
	readonly SOCKET_OPTIONS=()
fi

# Log init function info if provided
if [ -n "$INIT_FUNCTION" ]; then
	mcp_debug_log "INFO" "Using init function: $INIT_FUNCTION"

	# Derive server-id from init function if not explicitly provided
	# This is a hack for backwards compatibility and will be removed later
	if [ -z "$SERVER_ID" ]; then
		# Extract server-id by removing -mcp-enable suffix
		SERVER_ID="${INIT_FUNCTION%-mcp-enable}"
		mcp_debug_log "INFO" "Derived server-id from init function: $SERVER_ID"
	fi
else
	mcp_debug_log "INFO" "No init function specified"
fi

# Log server-id
if [ -n "$SERVER_ID" ]; then
	mcp_debug_log "INFO" "Using server-id: $SERVER_ID"
else
	# Default to "default" if not specified
	SERVER_ID="default"
	mcp_debug_log "INFO" "Using default server-id: $SERVER_ID"
fi

# Initialize MCP if init function is provided
if [ -n "$INIT_FUNCTION" ]; then
	# shellcheck disable=SC2124
	readonly INIT_CMD="timeout 60 emacsclient ${SOCKET_OPTIONS[@]+"${SOCKET_OPTIONS[@]}"} -e \"($INIT_FUNCTION)\""

	mcp_debug_log "INIT-CALL" "$INIT_CMD"

	# Execute the command and capture output and return code
	init_stderr_file="/tmp/mcp-init-stderr.$$-$(date +%s%N)"
	mcp_debug_log "INIT-STDERR-FILE" "$init_stderr_file"
	INIT_OUTPUT=$(eval "$INIT_CMD" 2>"$init_stderr_file")
	INIT_RC=$?

	# Log results
	mcp_debug_log "INIT-RC" "$INIT_RC"
	mcp_debug_log "INIT-OUTPUT" "$INIT_OUTPUT"
	if [ -s "$init_stderr_file" ]; then
		mcp_debug_log "INIT-STDERR" "$(cat "$init_stderr_file")"
	fi
	rm -f "$init_stderr_file"
else
	mcp_debug_log "INFO" "Skipping init function call (none provided)"
fi

# Process input and print response
while read -r line; do
	# Log the incoming request
	mcp_debug_log "REQUEST" "$line"

	# Base64 encode the raw JSON to avoid emacsclient transport issues
	# with a specific combination of length, UTF-8 characters, and quoting
	# that occurs in Test 5 with the Lithuanian letter 'ą'
	base64_input=$(echo -n "$line" | base64)
	mcp_debug_log "BASE64-INPUT" "$base64_input"

	# Process JSON-RPC request and return the result with proper UTF-8 encoding
	# Encode the response to base64 to avoid any character encoding issues
	# Handle nil responses from notifications by converting to empty string
	elisp_expr="(base64-encode-string (encode-coding-string (or (mcp-server-lib-process-jsonrpc (base64-decode-string \"$base64_input\") \"$SERVER_ID\") \"\") 'utf-8 t) t)"

	# Get response from emacsclient - capture stderr for debugging
	stderr_file="/tmp/mcp-stderr.$$-$(date +%s%N)"
	base64_response=$(timeout 60 emacsclient "${SOCKET_OPTIONS[@]+"${SOCKET_OPTIONS[@]}"}" -e "$elisp_expr" 2>"$stderr_file")

	# Check for stderr output
	if [ -s "$stderr_file" ]; then
		mcp_debug_log "EMACSCLIENT-STDERR" "$(cat "$stderr_file")"
	fi
	rm -f "$stderr_file"

	mcp_debug_log "BASE64-RESPONSE" "$base64_response"

	# Handle the base64 response - first strip quotes if present
	if [[ "$base64_response" == \"* && "$base64_response" == *\" ]]; then
		# Remove the surrounding quotes
		base64_response="${base64_response:1:${#base64_response}-2}"
		# Unescape any quotes inside
		base64_response="${base64_response//\\\"/\"}"
	fi

	# Decode the base64 content
	formatted_response=$(echo -n "$base64_response" | base64 -d)

	mcp_debug_log "RESPONSE" "$formatted_response"

	# Only output non-empty responses
	if [ -n "$formatted_response" ]; then
		# Output the response
		echo "$formatted_response"
	fi
done

# Stop MCP if stop function is provided
if [ -n "$STOP_FUNCTION" ]; then
	mcp_debug_log "INFO" "Stopping MCP with function: $STOP_FUNCTION"

	# shellcheck disable=SC2124
	readonly STOP_CMD="timeout 60 emacsclient ${SOCKET_OPTIONS[@]+"${SOCKET_OPTIONS[@]}"} -e \"($STOP_FUNCTION)\""

	mcp_debug_log "STOP-CALL" "$STOP_CMD"

	# Execute the command and capture output and return code
	STOP_OUTPUT=$(eval "$STOP_CMD" 2>&1)
	STOP_RC=$?

	# Log results
	mcp_debug_log "STOP-RC" "$STOP_RC"
	mcp_debug_log "STOP-OUTPUT" "$STOP_OUTPUT"
else
	mcp_debug_log "INFO" "Skipping stop function call (none provided)"
fi
