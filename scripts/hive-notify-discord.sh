#!/usr/bin/env bash

curl -s -H "Content-Type: application/json" -X POST "${DISCORD_WEBHOOK_URL}" -d '{
  "embeds": [{
    "title": "Hive Test Failure",
    "description": "Hive tests failed for [PR-'"${CHANGE_ID}"'](https://github.com/status-im/nimbus-eth1/pull/'"${CHANGE_ID}"')",
    "color": 15158332,
    "fields": [
      {"name": "Branch", "value": "['"${CHANGE_BRANCH}"'](https://github.com/status-im/nimbus-eth1/tree/'"${CHANGE_BRANCH}"')", "inline": true},
      {"name": "Build", "value": "[#'"${BUILD_NUMBER}"'](https://ci.status.im/blue/organizations/jenkins/nimbus-eth1%2Fplatforms%2Flinux%2Fx86_64%2Fhive/detail/PR-'"${CHANGE_ID}"'/'"${BUILD_NUMBER}"'/pipeline/)", "inline": true},
      {"name": "Simulation", "value": "'"${SIMULATION_NAME}"'", "inline": true},
      {"name": "Failed Stages", "value": "['"${FAILED_STAGES}"'](https://hive.nimbus.team/#summary-sort=name&suite=sync)", "inline": false}
    ]
  }]
}'
