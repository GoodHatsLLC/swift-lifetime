#!/usr/bin/env bash
set -euo pipefail

IMAGE="swift:latest"
NAME="swift-latest-swift-lifetime"
HOST_DIR="$(pwd)"
CONTAINER_DIR="/swift-lifetime-workspace"

# Pull image only if missing
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker pull swift
fi

container_exists() {
  docker container inspect "$NAME" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)" == "true" ]]
}

if [ "$#" -gt 0 ]; then
  if [ "$1" == "reset" ]; then
    docker container rm "$NAME"
    echo "removed $NAME"
    exit 0
  elif [ "$1" == "run" ]; then
    shift 1
  elif [ "$1" == "shell" ]; then
    shift 1
  else
    echo "
    USAGE: ./linux.sh <act> <params?>

    act:       params:
      run      <commands to run in container>
      shell
      reset
    "
  fi
fi

# Create container if it does not exist
if ! container_exists; then
  docker create \
    --privileged \
    --tty \
    --interactive \
    --name "$NAME" \
    --mount "type=bind,src=$HOST_DIR,dst=$CONTAINER_DIR" \
    --workdir "$CONTAINER_DIR" \
    "$IMAGE" /bin/bash >/dev/null
fi

# Start container if not running
if ! container_running; then
  docker start "$NAME" >/dev/null
fi

# If a command is provided, execute it and proxy exit code
if [ "$#" -gt 0 ]; then
  docker exec -it \
    --workdir "$CONTAINER_DIR" \
    "$NAME" "$@"
  exit $?
else
  # No command → interactive shell in /workspace
  docker exec -it \
    --workdir "$CONTAINER_DIR" \
    "$NAME" /bin/bash
fi
