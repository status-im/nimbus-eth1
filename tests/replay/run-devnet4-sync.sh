#! /bin/sh
#
# Connect to Devnet4 (aka Kintsugi in all but chainId)
#

self=`basename "$0"`

# Base directory for finding objects in the Nimbus file system
find_prefix="`dirname $0` . .. ../.. nimbus-eth1"

# Sub-find directory for various items
find_nimbus=". build"
find_genesis=". tests/customgenesis"
find_bootstrap=". tests/customgenesis"

# Name of custom genesis and bootstrap files
genesis_json=devnet4.json
bootstrap_txt=devnet4-enode.txt

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Find executable file
find_exe() { # Syntax: <exe-name> <subdir> ...
    exe="$1"
    shift
    for pfx in $find_prefix; do
	for sub; do
	    find \
		"$pfx/$sub" \
		-maxdepth 2 -type f -name "$exe" -perm /111 -print \
		2>/dev/null
	done
    done |
	# Beware, this is slow. On the other hand, uncommenting the next line
	# dumps all possible matches to the console.
	#tee /dev/tty |
	sed -e 's|/\./|/|' -eq
}

# Find non-executable file
find_file() { # Syntax: <file-name> <subdir> ...
    file="$1"
    shift
    for pfx in $find_prefix; do
	for sub; do
	    find \
		"$pfx/$sub" \
		-maxdepth 2 -type f -name "$file" -print \
		2>/dev/null
	done
    done |
	# Beware, this is slow. On the other hand, uncommenting the next line
	# dumps all possible matches to the console.
	#tee /dev/tty |
	sed -e 's|/\./|/|' -eq
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

case "$1" in
-h|--help)
    exec >&2
    echo "Usage: $self [additional-nimbus-options..]"
    exit
esac

nimbus=`find_exe nimbus $find_nimbus`
genesis=`find_file $genesis_json $find_genesis`
bootstrap=`find_file $bootstrap_txt $find_bootstrap`

set -x
$nimbus \
    --custom-network:"$genesis" \
    --bootstrap-file:"$bootstrap" \
    --terminal-total-difficulty:5000000000 \
    --prune-mode:full \
    $@ \
    2>&1

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
