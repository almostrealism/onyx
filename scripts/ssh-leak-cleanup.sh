#!/usr/bin/env bash
# ssh-leak-cleanup.sh — emergency cleanup of leaked SSH connections from
# Onyx. Run on every machine that has run Onyx recently. Safe to run more
# than once.
#
# What it does (in order):
#   1. Stops every Onyx-managed mux master via `ssh -O exit`.
#   2. Kills any stray `ssh` processes that have a ControlPath pointing
#      at ~/.ssh/onyx-mux/.
#   3. Removes leftover socket files in ~/.ssh/onyx-mux/.
#
# It does NOT quit Onyx itself. Quit Onyx first if you want the cleanup
# to be permanent.
#
# Usage:
#   bash scripts/ssh-leak-cleanup.sh
#
# Output is informative — every action is announced before it's taken.

set -uo pipefail

MUX_DIR="$HOME/.ssh/onyx-mux"
echo
echo "==> Onyx SSH leak cleanup"
echo "    mux dir: $MUX_DIR"
echo

# 1. Stop every recorded mux master cleanly. Each socket name encodes
#    the user@host via the running ssh process; the cheapest way to find
#    that is to look at the master's command line via lsof or ps.
if [[ -d "$MUX_DIR" ]]; then
    sockets=("$MUX_DIR"/*)
    if (( ${#sockets[@]} == 0 )) || [[ ! -e "${sockets[0]}" ]]; then
        echo "  no mux sockets present in $MUX_DIR"
    else
        for socket in "${sockets[@]}"; do
            [[ -S "$socket" ]] || continue
            # Find the master process that owns this socket.
            pid=$(lsof -t -- "$socket" 2>/dev/null | head -1 || true)
            if [[ -z "$pid" ]]; then
                echo "  $socket — no live master, will just delete"
                continue
            fi
            # Extract the user@host from the ssh command line.
            user_host=$(ps -o args= -p "$pid" 2>/dev/null \
                       | awk '{ for (i=1; i<=NF; i++) if ($i ~ /@/) { print $i; exit } }')
            if [[ -n "$user_host" ]]; then
                echo "  closing mux: $user_host (pid $pid)"
                ssh -o ControlPath="$socket" -O exit "$user_host" 2>/dev/null || true
            else
                echo "  closing mux: pid $pid (couldn't read user@host, killing instead)"
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done
    fi
fi

# 2. Kill any straggler ssh processes that reference the onyx-mux dir.
#    These are processes that didn't respond to -O exit or whose sockets
#    were already gone.
echo
echo "==> Hunting straggler ssh processes referencing onyx-mux"
stragglers=$(pgrep -fl "ControlPath=$MUX_DIR" 2>/dev/null || true)
if [[ -z "$stragglers" ]]; then
    echo "  none"
else
    echo "$stragglers" | while read -r pid rest; do
        echo "  killing pid $pid: $rest"
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 1
    # Any survivors get SIGKILL.
    stragglers=$(pgrep -fl "ControlPath=$MUX_DIR" 2>/dev/null || true)
    if [[ -n "$stragglers" ]]; then
        echo "$stragglers" | while read -r pid rest; do
            echo "  SIGKILL pid $pid"
            kill -KILL "$pid" 2>/dev/null || true
        done
    fi
fi

# 3. Remove socket files. After step 1 they should mostly be gone; this
#    cleans up any that the master had abandoned.
echo
echo "==> Removing leftover socket files"
if [[ -d "$MUX_DIR" ]]; then
    leftover=$(find "$MUX_DIR" -type s 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$leftover" == "0" ]]; then
        echo "  none"
    else
        find "$MUX_DIR" -type s -print -delete 2>/dev/null
    fi
fi

echo
echo "==> Done. If you still can't ssh into the affected host, run:"
echo "    ssh -o ControlMaster=no -o BatchMode=yes <user>@<host> true"
echo "    (forces a fresh connection that bypasses any local socket)"
echo
