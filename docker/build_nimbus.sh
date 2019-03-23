#!/bin/bash

set -euv
cd $(dirname "$0")

(cd nimbus && make push)

