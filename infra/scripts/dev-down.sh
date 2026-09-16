#!/usr/bin/env bash
# Stop processes started by dev-up.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="${ROOT}/.run"

stop_one() {
  local name="$1"
  local pidfile="${RUN_DIR}/${name}.pid"
  if [[ ! -f "${pidfile}" ]]; then
    echo "not running: ${name}"
    return
  fi
  local pid
  pid="$(cat "${pidfile}")"
  if kill -0 "${pid}" 2>/dev/null; then
    echo "stopping ${name} (pid ${pid})"
    kill "${pid}" 2>/dev/null || true
    # children of artisan serve / etc.
    sleep 0.2
    kill -9 "${pid}" 2>/dev/null || true
  else
    echo "stale pidfile: ${name}"
  fi
  rm -f "${pidfile}"
}

stop_one proxy
stop_one laravel
stop_one martin
echo "done"
