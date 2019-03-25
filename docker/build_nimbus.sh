#!/bin/bash

set -euv
cd $(dirname "$0")

export GIT_REVISION=$(git rev-parse HEAD)

(cd nimbus && make push)

