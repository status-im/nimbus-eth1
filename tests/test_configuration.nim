# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os],
  pkg/[unittest2],
  eth/[common, keys],
  stew/byteutils,
  ../nimbus/config,
  ../nimbus/common/[chain_config, context],
  ./test_helpers

proc configurationMain*() =
  suite "configuration test suite":
    const
      jsonDir = "tests" / "customgenesis"
      genesisFile = jsonDir / "calaveras.json"
      noGenesis = jsonDir / "nogenesis.json"
      noConfig = jsonDir / "noconfig.json"
      bootNode = "enode://a24ac7c5484ef4ed0c5eb2d36620ba4e4aa13b8c84684e1b4aab0cebea2ae45cb4d375b77eab56516d34bfbd3c1a833fc51296ff084b770b94fb9028c4d25ccf@52.169.42.101:30303"

    test "data-dir and key-store":
      let conf = makeTestConfig()
      check conf.dataDir.string == defaultDataDir()
      check conf.keyStore.string == defaultKeystoreDir()

      let cc = makeConfig(@["-d:apple\\bin", "-k:banana/bin"])
      check cc.dataDir.string == "apple\\bin"
      check cc.keyStore.string == "banana/bin"

      let dd = makeConfig(@["--data-dir:apple\\bin", "--key-store:banana/bin"])
      check dd.dataDir.string == "apple\\bin"
      check dd.keyStore.string == "banana/bin"

    test "chaindb-mode":
      let ee = makeConfig(@["--chaindb:aristo"])
      check ee.chainDbMode == ChainDbMode.Aristo

      let ff = makeConfig(@["--chaindb:ariPrune"])
      check ff.chainDbMode == ChainDbMode.AriPrune

    test "import":
      let aa = makeTestConfig()
      check aa.cmd == NimbusCmd.noCommand

      let bb = makeConfig(@["import", genesisFile])
      check bb.cmd == NimbusCmd.`import`
      check bb.blocksFile[0].string == genesisFile

    test "custom-network loading config file with no genesis data":
      # no genesis will fallback to geth compatibility mode
      let conf = makeConfig(@["--custom-network:" & noGenesis])
      check conf.networkParams.genesis.isNil.not

    test "custom-network loading config file with no 'config'":
      # no config will result in empty config, CommonRef keep working
      let conf = makeConfig(@["--custom-network:" & noConfig])
      check conf.networkParams.config.isNil == false

    test "network-id":
      let aa = makeTestConfig()
      check aa.networkId == MainNet
      check aa.networkParams != NetworkParams()

      let conf = makeConfig(@["--custom-network:" & genesisFile, "--network:345"])
      check conf.networkId == 345.NetworkId

    test "network-id first, custom-network next":
      let conf = makeConfig(@["--network:678", "--custom-network:" & genesisFile])
      check conf.networkId == 678.NetworkId

    test "network-id set, no custom-network":
      let conf = makeConfig(@["--network:678"])
      check conf.networkId == 678.NetworkId
      check conf.networkParams.genesis == Genesis()
      check conf.networkParams.config == ChainConfig()

    test "network-id not set, copy from chainId of custom network":
      let conf = makeConfig(@["--custom-network:" & genesisFile])
      check conf.networkId == 123.NetworkId

    test "network-id not set, sepolia set":
      let conf = makeConfig(@["--network:sepolia"])
      check conf.networkId == SepoliaNet

    test "network-id set, sepolia set":
      let conf = makeConfig(@["--network:sepolia", "--network:123"])
      check conf.networkId == 123.NetworkId

    test "rpc-api":
      let conf = makeTestConfig()
      let flags = conf.getRpcFlags()
      check { RpcFlag.Eth } == flags

      let aa = makeConfig(@["--rpc-api:eth"])
      let ax = aa.getRpcFlags()
      check { RpcFlag.Eth } == ax

      let bb = makeConfig(@["--rpc-api:eth", "--rpc-api:debug"])
      let bx = bb.getRpcFlags()
      check { RpcFlag.Eth, RpcFlag.Debug } == bx

      let cc = makeConfig(@["--rpc-api:eth,debug"])
      let cx = cc.getRpcFlags()
      check { RpcFlag.Eth, RpcFlag.Debug } == cx

    test "ws-api":
      let conf = makeTestConfig()
      let flags = conf.getWsFlags()
      check { RpcFlag.Eth } == flags

      let aa = makeConfig(@["--ws-api:eth"])
      let ax = aa.getWsFlags()
      check { RpcFlag.Eth } == ax

      let bb = makeConfig(@["--ws-api:eth", "--ws-api:debug"])
      let bx = bb.getWsFlags()
      check { RpcFlag.Eth, RpcFlag.Debug } == bx

      let cc = makeConfig(@["--ws-api:eth,debug"])
      let cx = cc.getWsFlags()
      check { RpcFlag.Eth, RpcFlag.Debug } == cx

    test "protocols":
      let conf = makeTestConfig()
      let flags = conf.getProtocolFlags()
      check ProtocolFlag.Eth in flags

      let bb = makeConfig(@["--protocols:eth"])
      let bx = bb.getProtocolFlags()
      check ProtocolFlag.Eth in bx

    test "bootstrap-node and bootstrap-file":
      let conf = makeTestConfig()
      let bootnodes = conf.getBootNodes()
      let bootNodeLen = bootnodes.len
      check bootNodeLen > 0 # mainnet bootnodes

      let aa = makeConfig(@["--bootstrap-node:" & bootNode])
      let ax = aa.getBootNodes()
      check ax.len == bootNodeLen + 1

      const
        bootFilePath = "tests" / "bootstrap"
        bootFileAppend = bootFilePath / "append_bootnodes.txt"
        bootFileOverride = bootFilePath / "override_bootnodes.txt"

      let bb = makeConfig(@["--bootstrap-file:" & bootFileAppend])
      let bx = bb.getBootNodes()
      check bx.len == bootNodeLen + 3

      let cc = makeConfig(@["--bootstrap-file:" & bootFileOverride])
      let cx = cc.getBootNodes()
      check cx.len == 3

    test "static-peers":
      let conf = makeTestConfig()
      check conf.getStaticPeers().len == 0

      let aa = makeConfig(@["--static-peers:" & bootNode])
      check aa.getStaticPeers().len == 1

      let bb = makeConfig(@["--static-peers:" & bootNode & "," & bootNode])
      check bb.getStaticPeers().len == 2

      let cc = makeConfig(@["--static-peers:" & bootNode, "--static-peers:" & bootNode])
      check cc.getStaticPeers().len == 2

    test "chainId of custom-network is oneof std network":
      const
        chainid1 = "tests" / "customgenesis" / "chainid1.json"

      let conf = makeConfig(@["--custom-network:" & chainid1])
      check conf.networkId == 1.NetworkId
      check conf.networkParams.config.londonBlock.get() == 1337
      check conf.getBootNodes().len == 0

    test "json-rpc enabled when json-engine api enabled and share same port":
      let conf = makeConfig(@["--engine-api", "--engine-api-port:8545", "--http-port:8545"])
      check:
        conf.engineApiEnabled == true
        conf.rpcEnabled == false
        conf.wsEnabled == false
        conf.engineApiWsEnabled == false
        conf.graphqlEnabled == false
        conf.engineApiServerEnabled
        conf.httpServerEnabled == false
        conf.shareServerWithEngineApi

    test "ws-rpc enabled when ws-engine api enabled and share same port":
      let conf = makeConfig(@["--ws", "--engine-api-ws", "--engine-api-port:8546", "--http-port:8546"])
      check:
        conf.engineApiWsEnabled
        conf.wsEnabled
        conf.engineApiEnabled == false
        conf.rpcEnabled == false
        conf.graphqlEnabled == false
        conf.engineApiServerEnabled
        conf.httpServerEnabled
        conf.shareServerWithEngineApi

    test "json-rpc stay enabled when json-engine api enabled and using different port":
      let conf = makeConfig(@["--rpc", "--engine-api", "--engine-api-port:8550", "--http-port:8545"])
      check:
        conf.engineApiEnabled
        conf.rpcEnabled
        conf.engineApiWsEnabled == false
        conf.wsEnabled == false
        conf.graphqlEnabled == false
        conf.httpServerEnabled
        conf.engineApiServerEnabled
        conf.shareServerWithEngineApi == false

    test "ws-rpc stay enabled when ws-engine api enabled and using different port":
      let conf = makeConfig(@["--ws", "--engine-api-ws", "--engine-api-port:8551", "--http-port:8546"])
      check:
        conf.engineApiWsEnabled
        conf.wsEnabled
        conf.engineApiEnabled == false
        conf.rpcEnabled == false
        conf.graphqlEnabled == false
        conf.httpServerEnabled
        conf.engineApiServerEnabled
        conf.shareServerWithEngineApi == false

    test "graphql enabled. ws, rpc, and engine api not enabled":
      let conf = makeConfig(@["--graphql"])
      check:
        conf.engineApiWsEnabled == false
        conf.wsEnabled == false
        conf.engineApiEnabled == false
        conf.rpcEnabled == false
        conf.graphqlEnabled == true
        conf.httpServerEnabled == true
        conf.engineApiServerEnabled == false
        conf.shareServerWithEngineApi == false

    let ctx = newEthContext()
    test "net-key random":
      let conf = makeConfig(@["--net-key:random"])
      check conf.netKey == "random"
      let rc = ctx.getNetKeys(conf.netKey, conf.dataDir.string)
      check rc.isOk

    test "net-key hex without 0x prefix":
      let conf = makeConfig(@["--net-key:9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"])
      check conf.netKey == "9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"
      let rc = ctx.getNetKeys(conf.netKey, conf.dataDir.string)
      check rc.isOk
      let pkhex = rc.get.seckey.toRaw.to0xHex
      check pkhex == "0x9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"

    test "net-key hex with 0x prefix":
      let conf = makeConfig(@["--net-key:0x9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"])
      check conf.netKey == "0x9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"
      let rc = ctx.getNetKeys(conf.netKey, conf.dataDir.string)
      check rc.isOk
      let pkhex = rc.get.seckey.toRaw.to0xHex
      check pkhex == "0x9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"

    test "net-key path":
      let conf = makeConfig(@["--net-key:nimcache/key.txt"])
      check conf.netKey == "nimcache/key.txt"
      let rc1 = ctx.getNetKeys(conf.netKey, conf.dataDir.string)
      check rc1.isOk
      let pkhex1 = rc1.get.seckey.toRaw.to0xHex
      let rc2 = ctx.getNetKeys(conf.netKey, conf.dataDir.string)
      check rc2.isOk
      let pkhex2 = rc2.get.seckey.toRaw.to0xHex
      check pkhex1 == pkhex2

    test "default key-store and default data-dir":
      let conf = makeTestConfig()
      check conf.keyStore.string == conf.dataDir.string / "keystore"

    test "custom key-store and custom data-dir":
      let conf = makeConfig(@["--key-store:banana", "--data-dir:apple"])
      check conf.keyStore.string == "banana"
      check conf.dataDir.string == "apple"

    test "default key-store and custom data-dir":
      let conf = makeConfig(@["--data-dir:apple"])
      check conf.dataDir.string == "apple"
      check conf.keyStore.string == "apple" / "keystore"

    test "custom key-store and default data-dir":
      let conf = makeConfig(@["--key-store:banana"])
      check conf.dataDir.string == defaultDataDir()
      check conf.keyStore.string == "banana"

when isMainModule:
  configurationMain()
