#!/bin/bash
#
# Script to run Nimbus-eth1 on the same networks Geth supports by name,
# with a trusted connection to a dedicated peer for that network.
#
# All protocols are disabled other than the minimum we need for block sync.
#
# This is very helpful for debugging and improving pipelined sync, and for
# improving the database and other processing, even though p2p sync is the
# endgame.
#
# - Discovery protocols are turned off
# - NAT hole punching protocols are turned off
# - Whisper protocol is turned off (`--protocols:eth`)
# - The only connection is to a single, active Geth for that network.
# - Each network's data is stored in a different location to avoid conflicts.
# - Each network is accessed by binding to a different port locally,
#   so we can run several at the same time.
# - Log level is set to `TRACE` because we can read them when we're not
#   swamped with discovery messages.  Sync isn't fast enough yet.
#
# The enode URLs below are public facing Geth instances that are syncing to
# each of the networks.  Nimbus-eth1 devs are free to use them for testing
# while they remain up.  However, better results will be obtained if those nodes
# also have the Nimbus instances as "trusted peers".
#
set -e -u -o pipefail

# First argument says which testnet, or use mainnet for that.
# Defaults to goerli if omitted.
testnet=${1:-goerli}

# Additional arguments after the first are passed to Nimbus.
shift || :

staticnode_geth_mainnet='enode://7af995207d620d363ffbdac3216c45140c8fc31a1a30cac94dfad94713ba6b03efeb4f8dd4c0d676ec3e32a9eac2804560c3d3001c7551a2bb955c1e5ce22d17@mainnet.geth.ethereum.arxlogic.com:30303'
staticnode_geth_goerli='enode://9a8651c02d14ffbf7e328cd6c31307d90c9411673deeec819a1b7a205eed121c7eea192146937958608eaebff25dcd232fce958f031bf82ba3d55deaac3d0715@goerli.geth.ethereum.arxlogic.com:30303';
staticnode_geth_ropsten='enode://861f2b16e3da33f2af677de97087dd489b17f9a0685fdaf751fb524fdf171cd4b8f02a5dc9e25a2730d1aa1b22176f5c88397b7f01180d032375d1526a8e1421@ropsten.geth.ethereum.arxlogic.com:30303'
staticnode_geth_rinkeby='enode://bb34c7a91c9895769f782cd1f0da88025f302960beebac305010b7395912b3835eb954426b3cf4be1b47bae4c32973d87688ace8cce412a3efb88baabc77bd98@rinkeby.geth.ethereum.arxlogic.com:30303'
staticnode_geth_yolov3='enode://a11e7ed2a1a21b9464619f77734b9dec76befbc5ebb95ac7820f45728bc42c30f9bd406a83ddc28b28141bc0a8469638467ad6a48065977e1ac8e8f1c7a1e6b4@yolov3.geth.ethereum.arxlogic.com:30303'

case $testnet in
    mainnet)
	net_option=          port=30193 staticnodes=$staticnode_geth_mainnet ;;
    goerli)
	net_option=--goerli  port=30194 staticnodes=$staticnode_geth_goerli ;;
    ropsten)
	net_option=--ropsten port=30195 staticnodes=$staticnode_geth_ropsten ;;
    rinkeby)
	net_option=--rinkeby port=30196 staticnodes=$staticnode_geth_rinkeby ;;
    yolov3)
	net_option=--yolov3  port=30197 staticnodes=$staticnode_geth_yolov3 ;;
    *)
	echo "Unrecognised network: $testnet" 1>&2; exit 1 ;;
esac

# Perform DNS name lookup for enodes with names.
# Geth supports this nowadays, but Nimbus does not.
resolve_enodes() {
    local node prefix suffix host port ip
    set --
    for node in $staticnodes; do
	case $node in
	    enode://*@*:*)
		prefix=${node%@*} suffix=${node##*@}
		host=${suffix%:*} port=${suffix##*:}
		case $host in
		    *[^0-9.]*)
			ip=$(host -t a "$host" 2>/dev/null)
			case $ip in
			    "$host has address "[0-9]*)
				ip=${ip##* has address }
				;;
			    *)
				echo "Name lookup for $host failed" 1>&2
				exit 1
				;;
			esac
			node=$prefix@$ip:$port
		esac
	esac
	set -- "$@" "$node"
    done
    staticnodes="$*"
}
resolve_enodes

datadir="$HOME"/.nimbus/"$testnet"

# Use a stable nodekey if we have one, to ensure the remote Geth almost always
# accepts our connections.  The nodekey's corresponding `enode` URL must be
# added with `admin.addTrustedPeer` to the remote Geth.  This isn't perfect.
# Sometimes Geth is too busy even for a trusted peer.  But usually it works.
#
# Note, this nodekey file isn't created automatically by nimbus-eth1 at the
# moment.  We have to have done it manually before now.
#
if [ -e "$datadir"/nimbus/nodekey ]; then
    nodekey=$(cat "$datadir"/nimbus/nodekey)
    if [ -n "$nodekey" ]; then
       set -- --nodekey:"$nodekey"
    fi
fi

# So the process name shows up without a path in `netstat`.
export PATH=$HOME/Status/nimbus-eth1/build:$PATH

exec nimbus \
     --datadir:"$datadir" $net_option \
     --prune:full \
     --logMetrics --logMetricsInterval:5 \
     --log-level:TRACE \
     --nodiscover --nat:none --port:$port --protocols:eth \
     --staticnodes:"$staticnodes" \
     "$@"
