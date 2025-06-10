#!/bin/bash
set -e

# Set up the routing needed for the simulation.
/setup.sh

echo "Client params: $CLIENT_PARAMS"

./bin/utp_test_app $CLIENT_PARAMS 2>&1 | tee /logs/service.log