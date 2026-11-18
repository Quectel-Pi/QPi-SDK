#!/bin/bash

set -ex
cd `dirname $0`

export IMAGENAME=quectel-pi-builder
docker images | grep $IMAGENAME >/dev/null 2>&1 || ./docker.build

DOCKER_MODE=()
if [ "${1:-}" = "--interactive" ]; then
	DOCKER_MODE=(--interactive)
	shift
fi

./docker.run "${DOCKER_MODE[@]}" "$*"
