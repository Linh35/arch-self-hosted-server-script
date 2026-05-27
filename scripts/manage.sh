#!/usr/bin/env bash
set -euo pipefail

# Run docker compose commands across all services in compose/.
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
      (cd "$d" && docker compose up -d)
    done
    ;;
  down)
    for d in $(services); do
      echo "==> $(basename "$d"): down"
      (cd "$d" && docker compose down)
    done
    ;;
  restart)
    for d in $(services); do
      echo "==> $(basename "$d"): restart"
      (cd "$d" && docker compose restart)
    done
    ;;
  pull)
    for d in $(services); do
      echo "==> $(basename "$d"): pull"
      (cd "$d" && docker compose pull)
    done
    ;;
  ps)
    for d in $(services); do
      echo "==> $(basename "$d")"
      (cd "$d" && docker compose ps)
    done
    ;;
  logs)
    svc=${2:-}
    if [[ -z "$svc" || ! -d "$COMPOSE_ROOT/$svc" ]]; then
      echo "usage: $0 logs <service>" >&2
      echo "available: $(services | xargs -n1 basename | tr '\n' ' ')" >&2
      exit 1
    fi
    cd "$COMPOSE_ROOT/$svc" && docker compose logs -f
    ;;
  *)
    echo "usage: $0 {up|down|restart|pull|ps|logs <service>}" >&2
    exit 1
    ;;
esac
