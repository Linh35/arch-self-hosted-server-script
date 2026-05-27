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

HERE="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_ROOT="$HERE/compose"

services() {
  find "$COMPOSE_ROOT" -mindepth 2 -maxdepth 2 -name docker-compose.yml -printf '%h\n' | sort
}

cmd=${1:-}
case "$cmd" in
  up)
    for d in $(services); do
      echo "==> $(basename "$d"): up"
      (cd "$d" && podman-compose up -d)
    done
    ;;
  down)
    for d in $(services); do
      echo "==> $(basename "$d"): down"
      (cd "$d" && podman-compose down)
    done
    ;;
  restart)
    for d in $(services); do
      echo "==> $(basename "$d"): restart"
      (cd "$d" && podman-compose restart)
    done
    ;;
  pull)
    for d in $(services); do
      echo "==> $(basename "$d"): pull"
      (cd "$d" && podman-compose pull)
    done
    ;;
  ps)
    for d in $(services); do
      echo "==> $(basename "$d")"
      (cd "$d" && podman-compose ps)
    done
    ;;
  logs)
    svc=${2:-}
    if [[ -z "$svc" || ! -d "$COMPOSE_ROOT/$svc" ]]; then
      echo "usage: $0 logs <service>" >&2
      echo "available: $(services | xargs -n1 basename | tr '\n' ' ')" >&2
      exit 1
    fi
    cd "$COMPOSE_ROOT/$svc" && podman-compose logs -f
    ;;
  *)
    echo "usage: $0 {up|down|restart|pull|ps|logs <service>}" >&2
    exit 1
    ;;
esac
