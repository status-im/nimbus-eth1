#!/bin/bash

# Compare the committed submodule pins of eth1 against those of nimbus-eth2.
# eth1 must be pinned at the same commit as eth2, or at a newer one (i.e. the
# eth2 commit must appear in the history of the eth1 commit).

cd "$(dirname "${BASH_SOURCE[0]}")"/..

# exit codes
readonly E_OK=0 E_MISMATCH=1 E_UNCHECKABLE=2

# Print the commit a submodule is pinned at in the given repo (committed pin,
# not the working tree). Prints nothing if the path is not a submodule there.
pinned_commit() {
  local entry
  entry=$(git -C "$1" ls-tree HEAD -- "$2" 2>/dev/null)
  # ls-tree output: "<mode> <type> <sha>\t<path>"; only gitlinks are submodules
  if [ -n "$entry" ] && [ "$(printf '%s' "$entry" | awk '{print $1}')" = "160000" ]; then
    printf '%s' "$entry" | awk '{print $3}'
  fi
}

fail_uncheckable() {
  echo "error: cannot check $1: eth2 commit $2 is not present in the eth1 submodule" >&2
  echo "  (fetch a full clone of $1, e.g. 'git -C $1 fetch --unshallow origin')" >&2
  exit "$E_UNCHECKABLE"
}

# Ensure the given commit is available in a submodule so that an ancestry check
# is possible. A shallow/depth-limited checkout may not contain it, so fetch the
# full history: unshallow, then a plain fetch, then the specific commit from the
# local nimbus-eth2 clone (which always has it checked out). Quiet on success;
# returns non-zero (with a diagnostic) only if the commit still can't be resolved.
ensure_commit() {
  local dep="$1" commit="$2"
  git -C "$dep" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  local eth2clone
  eth2clone="$(pwd)/vendor/nimbus-eth2/$dep"
  git -C "$dep" fetch -q --unshallow origin 2>/dev/null \
    || git -C "$dep" fetch -q origin 2>/dev/null \
    || git -C "$dep" fetch -q "$eth2clone" "$commit" 2>/dev/null
  if git -C "$dep" cat-file -e "$commit^{commit}" 2>/dev/null; then
    return 0
  fi
  echo "  [debug] $dep: eth2 commit $commit still missing after fetch (is-shallow=$(git -C "$dep" rev-parse --is-shallow-repository 2>/dev/null))" >&2
  return 1
}

COMMON=$(ls vendor/ vendor/nimbus-eth2/vendor/ -1 | sort | uniq -d | sed -e "sX^Xvendor/X")

if [[ "$1" == "--update" ]]; then
  for dep in $COMMON; do
    eth1_commit=$(pinned_commit . "$dep")
    eth2_commit=$(pinned_commit vendor/nimbus-eth2 "$dep")
    # skip deps that are not submodules on one or both sides, or already equal
    [ -z "$eth1_commit" ] && continue
    [ -z "$eth2_commit" ] && continue
    [ "$eth1_commit" = "$eth2_commit" ] && continue
    # the eth2 commit must be present in the eth1 submodule to compare history
    ensure_commit "$dep" "$eth2_commit" || fail_uncheckable "$dep" "$eth2_commit"
    # eth2 commit is an ancestor of the eth1 commit -> eth1 is newer
    if git -C "$dep" merge-base --is-ancestor "$eth2_commit" "$eth1_commit"; then
      if [[ "$2" == "--downgrade" ]]; then
        git -C "$dep" checkout "$eth2_commit"
      else
        echo "skipping $dep: eth1 is ahead of eth2 (use --downgrade to force)"
      fi
    else
      git -C "$dep" checkout "$eth2_commit"
    fi
  done
else
  missing=""
  # columns of the invalid submodules (submodule, eth1 ref, eth2 ref)
  declare -a c0=() c1=() c2=()
  # single pass over nimbus-eth2's submodules: classify each as valid, invalid
  # (pinned older than eth2), or missing (not vendored in eth1)
  for name in $(ls vendor/nimbus-eth2/vendor/ -1); do
    dep="vendor/$name"
    eth1_commit=$(pinned_commit . "$dep")
    eth2_commit=$(pinned_commit vendor/nimbus-eth2 "$dep")
    # not a submodule in eth2 (e.g. a plain file) -> ignore
    [ -z "$eth2_commit" ] && continue
    # not a submodule in eth1 -> missing
    if [ -z "$eth1_commit" ]; then
      url=$(git -C vendor/nimbus-eth2 config --file .gitmodules --get "submodule.$dep.url")
      missing+="  git submodule add $url $dep"$'\n'
      continue
    fi
    # equal -> valid
    [ "$eth1_commit" = "$eth2_commit" ] && continue
    # the eth2 commit must be present in the eth1 submodule to compare history
    ensure_commit "$dep" "$eth2_commit" || fail_uncheckable "$dep" "$eth2_commit"
    # valid when the eth2 commit is an ancestor of the eth1 commit (i.e. the
    # eth2 commit appears in the history of the eth1 commit)
    if git -C "$dep" merge-base --is-ancestor "$eth2_commit" "$eth1_commit"; then
      continue
    fi
    # invalid: eth1 is pinned older than eth2
    c0+=("$dep")
    c1+=("$(git -C "$dep" log -1 --format='%h (%cd)' --date=short "$eth1_commit")")
    # read the eth2 commit info from the eth1 checkout (ensure_commit has fetched
    # it in there); the nimbus-eth2/vendor submodules may not be initialized
    c2+=("$(git -C "$dep" log -1 --format='%h (%cd)' --date=short "$eth2_commit")")
  done
  # print the invalid submodules as a space-aligned markdown table (the workflow
  # tees this to the job summary in CI)
  if [ "${#c0[@]}" -gt 0 ]; then
    h0="Submodule"; h1="eth1"; h2="eth2"
    w0=${#h0}; w1=${#h1}; w2=${#h2}
    for x in "${c0[@]}"; do [ ${#x} -gt "$w0" ] && w0=${#x}; done
    for x in "${c1[@]}"; do [ ${#x} -gt "$w1" ] && w1=${#x}; done
    for x in "${c2[@]}"; do [ ${#x} -gt "$w2" ] && w2=${#x}; done
    dashes() { printf '%*s' "$1" '' | tr ' ' '-'; }
    echo "## Submodules pinned older than nimbus-eth2"
    echo
    printf '| %-*s | %-*s | %-*s |\n' "$w0" "$h0" "$w1" "$h1" "$w2" "$h2"
    printf '| %s | %s | %s |\n' "$(dashes "$w0")" "$(dashes "$w1")" "$(dashes "$w2")"
    for i in "${!c0[@]}"; do
      printf '| %-*s | %-*s | %-*s |\n' "$w0" "${c0[$i]}" "$w1" "${c1[$i]}" "$w2" "${c2[$i]}"
    done
    printf '\n'
  fi
  if [ -n "$missing" ]; then
    echo "## Submodules in eth2 but not in eth1"
    printf '%s' "$missing"
  fi
  # return an error when there's a mismatch so the CI job fails
  [ "${#c0[@]}" -gt 0 ] && exit "$E_MISMATCH"
  exit "$E_OK"
fi
