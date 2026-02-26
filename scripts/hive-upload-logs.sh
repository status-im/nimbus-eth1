#!/usr/bin/env bash

LOGS_DIR="${WORKSPACE}/hive/workspace/logs"
REMOTE_HOST="jenkins@node-01.he-eu-hel1.ci.hive.status.im"
REMOTE_PATH="/home/jenkins/hive/workspace/logs/"

if [ ! -d "${LOGS_DIR}" ]; then
  echo "No logs directory found, skipping upload"
  exit 0
fi

scp -o StrictHostKeyChecking=no -r "${LOGS_DIR}"/* "${REMOTE_HOST}:${REMOTE_PATH}"
