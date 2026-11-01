#!/usr/bin/env bash
# Live progress of the Amarok and MariaDB builds. Usage: scripts/macos/progress.sh [-w]
show() {
  for pair in "Amarok:$HOME/amarok-build.log" "MariaDB:$HOME/mariadb-build.log"; do
    name="${pair%%:*}"; log="${pair#*:}"
    [ -f "$log" ] || { echo "$name: no log"; continue; }
    step=$(grep -oE '^\[[0-9]+/[0-9]+\]' "$log" | tail -1)
    cur=${step#[}; cur=${cur%%/*}; tot=${step#*/}; tot=${tot%]}
    pct=$(( ${tot:-1} > 0 ? 100 * ${cur:-0} / ${tot:-1} : 0 ))
    echo "== $name: ${step:-?} (${pct}%)  failures: $(grep -c '^FAILED' "$log")  errors: $(grep -c 'error:' "$log")"
    echo "   last: $(grep -E '^\[[0-9]+/' "$log" | tail -1 | cut -c1-110)"
    grep -E '^FAILED|error:' "$log" | sort -u | tail -3 | cut -c1-140 | sed 's/^/   ! /'
  done
}
if [ "$1" = "-w" ]; then while true; do clear; date; show; sleep 5; done; else show; fi
