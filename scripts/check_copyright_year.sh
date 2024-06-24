#!/usr/bin/env bash

# Copyright (c) 2023-2024 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

excluded_files="config.yaml|.gitmodules|.gitignore"
excluded_extensions="json|md|png|txt|toml|gz|key|rlp|era1|cfg|py|sh|in"

current_year=$(date +"%Y")
outdated_files=()
while read -r file; do
  if ! grep -qE 'Copyright \(c\) .*'$current_year' Status Research & Development GmbH' "$file"; then
    outdated_files+=("$file")
  fi
done < <(git diff --name-only --diff-filter=AM --ignore-submodules HEAD^ HEAD | grep -vE '(\.('$excluded_extensions')|'$excluded_files')$' || true)

if (( ${#outdated_files[@]} )); then
  echo "The following files do not have an up-to-date copyright year:"
  for file in "${outdated_files[@]}"; do
    echo "- $file"
  done
  exit 2
fi
