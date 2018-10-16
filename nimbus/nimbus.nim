# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  os, strutils, net, eth_common, db/[storage_types, db_chain],
  asyncdispatch2, json_rpc/rpcserver, eth_keys,
  eth_p2p, eth_p2p/rlpx_protocols/[eth_protocol, les_protocol],
  eth_p2p/blockchain_sync,
  config, genesis, rpc/[common, p2p], p2p/chain,
  eth_trie/db

const UseSqlite = false

when UseSqlite:
  import db/backends/sqlite_backend
else:
  import db/backends/rocksdb_backend

## TODO:
## * No IPv6 support
## * No multiple bind addresses support
## * No database support

const
  nimbusClientId = "nimbus 0.1.0"

when not defined(windows):
  from posix import SIGINT, SIGTERM

type
  NimbusState = enum
    Starting, Running, Stopping, Stopped

  NimbusObject = ref object
    rpcServer*: RpcHttpServer
    ethNode*: EthereumNode
    state*: NimbusState

proc initializeEmptyDb(db: BaseChainDB) =
  echo "Writing genesis to DB"
  let networkId = getConfiguration().net.networkId.toPublicNetwork()
  if networkId == CustomNet:
    raise newException(Exception, "Custom genesis not implemented")
  else:
    defaultGenesisBlockForNetwork(networkId).commit(db)

proc start(): NimbusObject =
  var nimbus = NimbusObject()
  var conf = getConfiguration()

  ## Creating RPC Server
  if RpcFlags.Enabled in conf.rpc.flags:
    nimbus.rpcServer = newRpcHttpServer(conf.rpc.binds)
    setupCommonRpc(nimbus.rpcServer)

  ## Creating P2P Server
  if conf.net.nodekey.isZeroKey():
    conf.net.nodekey = newPrivateKey()

  var keypair: KeyPair
  keypair.seckey = conf.net.nodekey
  keypair.pubkey = conf.net.nodekey.getPublicKey()

  var address: Address
  address.ip = parseIpAddress("0.0.0.0")
  address.tcpPort = Port(conf.net.bindPort)
  address.udpPort = Port(conf.net.discPort)

  createDir(conf.dataDir)
  let trieDB = trieDB newChainDb(conf.dataDir)
  let chainDB = newBaseChainDB(trieDB)

  if canonicalHeadHashKey().toOpenArray notin trieDB:
    initializeEmptyDb(chainDb)
    assert(canonicalHeadHashKey().toOpenArray in trieDB)

  nimbus.ethNode = newEthereumNode(keypair, address, conf.net.networkId,
                                   nil, nimbusClientId)

  nimbus.ethNode.chain = newChain(chainDB)

  if RpcFlags.Enabled in conf.rpc.flags:
    setupEthRpc(nimbus.ethNode, chainDB, nimbus.rpcServer)

  ## Starting servers
  nimbus.state = Starting
  if RpcFlags.Enabled in conf.rpc.flags:
    nimbus.rpcServer.rpc("admin_quit") do() -> string:
      nimbus.state = Stopping
      result = "EXITING"
    nimbus.rpcServer.start()

  waitFor nimbus.ethNode.connectToNetwork(conf.net.bootNodes,
    enableDiscovery = NoDiscover notin conf.net.flags)

  # TODO: temp code until the CLI/RPC interface is fleshed out
  let status = waitFor nimbus.ethNode.fastBlockchainSync()
  if status != syncSuccess:
    echo "Block sync failed: ", status

  nimbus.state = Running
  result = nimbus

proc stop*(nimbus: NimbusObject) {.async.} =
  echo "Graceful shutdown"
  nimbus.rpcServer.stop()

proc process*(nimbus: NimbusObject) =
  if nimbus.state == Running:
    when not defined(windows):
      proc signalBreak(udata: pointer) =
        nimbus.state = Stopping
      # Adding SIGINT, SIGTERM handlers
      # discard addSignal(SIGINT, signalBreak)
      # discard addSignal(SIGTERM, signalBreak)

    # Main loop
    while nimbus.state == Running:
      poll()

    # Stop loop
    waitFor nimbus.stop()

when isMainModule:
  var message: string

  ## Pring Nimbus header
  echo NimbusHeader

  ## Processing command line arguments
  if processArguments(message) != ConfigStatus.Success:
    echo message
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message
      quit(QuitSuccess)

  var nimbus = start()
  nimbus.process()
