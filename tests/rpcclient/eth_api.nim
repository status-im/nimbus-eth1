import
  strutils,
  json_serialization/std/[sets, net],
  json_rpc/[client, jsonmarshal],
  web3/conversions,
  eth/common,
  ../../nimbus/rpc/[rpc_types, hexstrings]

export
  rpc_types, conversions, hexstrings

from os import DirSep, AltSep
template sourceDir: string = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]

createRpcSigs(RpcClient, sourceDir & "/ethcallsigs.nim")
