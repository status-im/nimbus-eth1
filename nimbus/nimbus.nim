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
  eth_p2p, eth_p2p/rlpx_protocols/[eth, les],
  config, rpc/[common, p2p],
  eth_trie

const UseSqlite = true

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

proc newTrieDb(): TrieDatabaseRef =
  # XXX: Setup db storage location according to config
  result = trieDB(newChainDb(":memory:"))

proc initializeEmptyDb(db: BaseChainDB) =
  echo "Initializing empty DB (TODO)"

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

  let trieDB = newTrieDb()
  let chainDB = newBaseChainDB(trieDB)

  if canonicalHeadHashKey().toOpenArray notin trieDB:
    initializeEmptyDb(chainDb)

  nimbus.ethNode = newEthereumNode(keypair, address, conf.net.networkId,
                                   nil, nimbusClientId)

  nimbus.ethNode.chain = chainDB

  if RpcFlags.Enabled in conf.rpc.flags:
    setupP2PRpc(nimbus.ethNode, nimbus.rpcServer)

  ## Starting servers
  nimbus.state = Starting
  if RpcFlags.Enabled in conf.rpc.flags:
    nimbus.rpcServer.rpc("admin_quit") do() -> string:
      nimbus.state = Stopping
      result = "EXITING"
    nimbus.rpcServer.start()

  waitFor nimbus.ethNode.connectToNetwork(conf.net.bootNodes)

  # TODO: temp code until the CLI/RPC interface is fleshed out
  if os.getenv("START_SYNC") == "1":
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
      discard addSignal(SIGINT, signalBreak)
      discard addSignal(SIGTERM, signalBreak)

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
