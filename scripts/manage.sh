#!/usr/bin/env bash
set -euo pipefail

# Wraps podman-compose across all stacks in compose/.
# Usage:
#   ./scripts/manage.sh up           start everything
#   ./scripts/manage.sh down         stop everything
#   ./scripts/manage.sh restart      restart everything
#   ./scripts/manage.sh pull         pull latest images
#   ./scripts/manage.sh ps           status of all stacks
#   ./scripts/manage.sh logs <svc>   tail logs for one stack
#
# Honours DRY_RUN=1 to print podman-compose commands instead of running them.

SCRIPT_NAME=manage
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

COMPOSE_ROOT="$REPO_ROOT/compose"

# Single source of truth for the storage location: the repo-root .env. Read it
# in a subshell so only STORAGE_ROOT crosses into the environment (per-stack
# .env files keep owning everything else). podman-compose then substitutes it.
sr="$( set -a; [[ -f "$REPO_ROOT/.env" ]] && source "$REPO_ROOT/.env" 2>/dev/null; printf '%s' "${STORAGE_ROOT:-}" )"
[[ -n "$sr" ]] && export STORAGE_ROOT="$sr"

services() {
  find "$COMPOSE_ROOT" -mindepth 2 -maxdepth 2 -name docker-compose.yml -printf '%h\n' | sort
}

cmd=${1:-}
case "$cmd" in
  up|down|restart|pull)
    for d in $(services); do
      echo "==> $(basename "$d"): $cmd"
      args=("$cmd")
      [[ "$cmd" == up ]] && args+=("-d")
      ( cd "$d" && run podman-compose "${args[@]}" )
    done
    ;;
  ps)
    for d in $(services); do
      echo "==> $(basename "$d")"
      ( cd "$d" && run podman-compose ps )
    done
    ;;
  logs)
    svc=${2:-}
    if [[ -z "$svc" || ! -d "$COMPOSE_ROOT/$svc" ]]; then
      echo "usage: $0 logs <service>" >&2
      echo "available: $(services | xargs -n1 basename | tr '\n' ' ')" >&2
      exit 1
    fi
    cd "$COMPOSE_ROOT/$svc" && run podman-compose logs -f
    ;;
  *)
    echo "usage: $0 {up|down|restart|pull|ps|logs <service>}" >&2
    exit 1
    ;;
esac
