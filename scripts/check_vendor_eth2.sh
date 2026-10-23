#!/bin/bash

# Compare the committed submodule pins of eth1 against those of nimbus-eth2.
# eth1 must be pinned at the same commit as eth2, or at a newer one (i.e. the
# eth2 commit must appear in the history of the eth1 commit).

cd "$(dirname "${BASH_SOURCE[0]}")"/..

# exit codes
readonly E_OK=0 E_UNCHECKABLE=2

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
    git -C "$dep" cat-file -e "$eth2_commit^{commit}" 2>/dev/null \
      || fail_uncheckable "$dep" "$eth2_commit"
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
  outdated=0
  for dep in $COMMON; do
    eth1_commit=$(pinned_commit . "$dep")
    eth2_commit=$(pinned_commit vendor/nimbus-eth2 "$dep")
    # skip deps that are not submodules on one or both sides, or already equal
    [ -z "$eth1_commit" ] && continue
    [ -z "$eth2_commit" ] && continue
    [ "$eth1_commit" = "$eth2_commit" ] && continue
    # the eth2 commit must be present in the eth1 submodule to compare history
    git -C "$dep" cat-file -e "$eth2_commit^{commit}" 2>/dev/null \
      || fail_uncheckable "$dep" "$eth2_commit"
    # eth1 is OK when the eth2 commit is an ancestor of the eth1 commit
    # (i.e. the eth2 commit appears in the history of the eth1 commit)
    if git -C "$dep" merge-base --is-ancestor "$eth2_commit" "$eth1_commit"; then
      : # eth1 is equal or newer than eth2
    else
      eth1_info=$(git -C "$dep" show -s --format="%h (%ad)" --date=short "$eth1_commit")
      eth2_info=$(git -C vendor/nimbus-eth2/"$dep" show -s --format="%h (%ad)" --date=short "$eth2_commit")
      # anchor the warning on the submodule's line in .gitmodules
      line=$(grep -nF "[submodule \"$dep\"]" .gitmodules | head -n1 | cut -d: -f1)
      [ -z "$line" ] && line=1
      echo "::warning file=.gitmodules,line=${line}::${dep} is pinned older than nimbus-eth2: eth1 ${eth1_info} vs eth2 ${eth2_info}"
      outdated=$((outdated+1))
    fi
  done
  for dep in $(ls vendor/nimbus-eth2/vendor/ -1); do
    if [ ! -d "vendor/$dep" ]; then
      url=$(git -C vendor/nimbus-eth2 config --file .gitmodules --get "submodule.vendor/$dep.url")
      echo "missing: $dep"
      echo "  git submodule add $url vendor/$dep"
    fi
  done
  if [ "$outdated" -gt 0 ]; then
    echo "warning: $outdated eth1 submodule(s) pinned older than their nimbus-eth2 counterpart (see annotations)"
  fi
  # do not fail the job; outdated submodules are reported as warnings above
  exit "$E_OK"
fi
