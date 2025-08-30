#!/usr/bin/env bash

# Copyright (c) 2025 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

remove_quotes() {
  local str="$1"
  # Remove any quotes
  str="${str//\"/}"
  # Remove any spaces
  str="${str// /}"
  echo "$str"
}

while read -r line; do
  if [[ "$line" == *"NimbusMajor*"* ]]; then
    NIMBUS_MAJOR=$(remove_quotes ${line##*=})
  fi
  if [[ "$line" == *"NimbusMinor*"* ]]; then
    NIMBUS_MINOR=$(remove_quotes ${line##*=})
  fi
  if [[ "$line" == *"NimbusPatch*"* ]]; then
    NIMBUS_PATCH=$(remove_quotes ${line##*=})
    break
  fi
done < execution_chain/version.nim

# Search 'version' from 'nimbus.nimble'
while read -r line; do
  if [[ "$line" == "version"* ]]; then
    VERSION_IN_NIMBLE_FILE=$(remove_quotes ${line##*=})
    break
  fi
done < nimbus.nimble

NIMBUS_VERSION=$NIMBUS_MAJOR.$NIMBUS_MINOR.$NIMBUS_PATCH

if [[ "$NIMBUS_VERSION" != "$VERSION_IN_NIMBLE_FILE" ]]; then
  echo "NimbusVersion($NIMBUS_VERSION) doesn't match version in .nimble file($VERSION_IN_NIMBLE_FILE)"
  exit 2
fi
