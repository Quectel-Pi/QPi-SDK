#!/bin/bash

set -ex
cd `dirname $0`

export IMAGENAME=quectel-pi-builder
docker images | grep $IMAGENAME >/dev/null 2>&1 || ./docker.build
./docker.build
./docker.run "$*"
