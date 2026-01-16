# Nimbus
# Copyright (c) 2019-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, strutils, importutils],
  pkg/[unittest2],
  eth/common/[base, keys],
  eth/net/nat,
  eth/enr/enr,
  stew/byteutils,
  ../execution_chain/[common, conf],
  ../execution_chain/networking/netkeys,
  ./test_helpers

func `==`*(a, b: OutDir): bool =
  a.string == b.string

proc configurationMain*() =
  suite "configuration test suite":
    const
      jsonDir = "tests" / "customgenesis"
      genesisFile = jsonDir / "calaveras.json"
      noGenesis = jsonDir / "nogenesis.json"
      noConfig = jsonDir / "noconfig.json"
      bootNode = "enode://a24ac7c5484ef4ed0c5eb2d36620ba4e4aa13b8c84684e1b4aab0cebea2ae45cb4d375b77eab56516d34bfbd3c1a833fc51296ff084b770b94fb9028c4d25ccf@52.169.42.101:30303"

    test "data-dir and key-store":
      let config = makeTestConfig()
      check config.dataDir() == defaultDataDir("", "mainnet")
      check config.keyStoreDir == defaultDataDir("", "mainnet") / "keystore"

      let cc = makeConfig(@["-d:apple\\bin", "-k:banana/bin"])
      check cc.dataDir() == "apple\\bin"
      check cc.keyStoreDir == "banana/bin"

      let dd = makeConfig(@["--data-dir:apple\\bin", "--key-store:banana/bin"])
      check dd.dataDir() == "apple\\bin"
      check dd.keyStoreDir == "banana/bin"

    test "import-rlp":
      let aa = makeTestConfig()
      check aa.cmd == NimbusCmd.executionClient

      let bb = makeConfig(@["import-rlp", genesisFile])
      check bb.cmd == NimbusCmd.`import-rlp`
      check bb.blocksFile[0].string == genesisFile

    test "network loading config file with no genesis data":
      # no genesis will fallback to geth compatibility mode
      let config = makeConfig(@["--network:" & noGenesis])
      check config.networkParams.genesis.isNil.not

    test "network loading config file with no 'config'":
      # no config will result in empty config, CommonRef keep working
      let config = makeConfig(@["--network:" & noConfig])
      check config.networkParams.config.isNil == false

    test "network-id":
      let aa = makeTestConfig()
      check aa.networkId == MainNet
      check aa.networkParams != NetworkParams()

      let config = makeConfig(@["--network:" & genesisFile, "--network:345"])
      check config.networkId == 345.u256

    test "network-id first, network next":
      let config = makeConfig(@["--network:678", "--network:" & genesisFile])
      check config.networkId == 678.u256

    test "network-id set, no network":
      let config = makeConfig(@["--network:678"])
      check config.networkId == 678.u256
      check config.networkParams.genesis == Genesis()
      check config.networkParams.config == ChainConfig()

    test "network-id not set, copy from chainId of custom network":
      let config = makeConfig(@["--network:" & genesisFile])
      check config.networkId == 123.u256

    test "network-id not set, sepolia set":
      let config = makeConfig(@["--network:sepolia"])
      check config.networkId == SepoliaNet

    test "network-id set, sepolia set":
      let config = makeConfig(@["--network:sepolia", "--network:123"])
      check config.networkId == 123.u256

    test "rpc-api":
      let config = makeTestConfig()
      let flags = config.getRpcFlags()
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

      let dd = makeConfig(@["--rpc-api:admin"])
      let dx = dd.getRpcFlags()
      check { RpcFlag.Admin } == dx

      let ee = makeConfig(@["--rpc-api:eth,admin"])
      let ex = ee.getRpcFlags()
      check { RpcFlag.Eth, RpcFlag.Admin } == ex

    test "ws-api":
      let config = makeTestConfig()
      let flags = config.getWsFlags()
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

    test "--bootstrap-node and --bootstrap-file":
      let config = makeTestConfig()
      let bootnodes = config.getBootstrapNodes()
      let bootNodeLen = bootnodes.enodes.len
      check bootNodeLen > 0 # mainnet bootnodes

      let aa = makeConfig(@["--bootstrap-node:" & bootNode])
      let ax = aa.getBootstrapNodes()
      check ax.enodes.len == bootNodeLen + 1

      let bb = makeConfig(@["--bootstrap-node:" & bootNode & "," & bootNode])
      check bb.getBootstrapNodes().enodes.len == bootNodeLen + 2

      let cc = makeConfig(@["--bootstrap-node:" & bootNode, "--bootstrap-node:" & bootNode])
      check cc.getBootstrapNodes().enodes.len == bootNodeLen + 2

      const
        bootFilePath = "tests" / "bootstrap"
        bootFileAppend = bootFilePath / "append_bootnodes.txt"

      let dd = makeConfig(@["--bootstrap-file:" & bootFileAppend])
      let dx = dd.getBootstrapNodes()
      check dx.enodes.len == bootNodeLen + 3

    test "static-peers":
      let config = makeTestConfig()
      check config.getStaticPeers().enodes.len == 0

      let aa = makeConfig(@["--static-peers:" & bootNode])
      check aa.getStaticPeers().enodes.len == 1

      let bb = makeConfig(@["--static-peers:" & bootNode & "," & bootNode])
      check bb.getStaticPeers().enodes.len == 2

      let cc = makeConfig(@["--static-peers:" & bootNode, "--static-peers:" & bootNode])
      check cc.getStaticPeers().enodes.len == 2

    test "chainId of network is oneof std network":
      const
        chainid1 = "tests" / "customgenesis" / "chainid1.json"

      let config = makeConfig(@["--network:" & chainid1])
      check config.networkId == 1.u256
      check config.networkParams.config.londonBlock.get() == 1337
      check config.getBootstrapNodes().enodes.len == 0

    test "json-rpc enabled when json-engine api enabled and share same port":
      let config = makeConfig(@["--engine-api", "--engine-api-port:8545", "--http-port:8545"])
      check:
        config.engineApiEnabled == true
        config.rpcEnabled == false
        config.wsEnabled == false
        config.engineApiWsEnabled == false
        config.engineApiServerEnabled
        config.httpServerEnabled == false
        config.shareServerWithEngineApi

    test "ws-rpc enabled when ws-engine api enabled and share same port":
      let config = makeConfig(@["--ws", "--engine-api-ws", "--engine-api-port:8546", "--http-port:8546"])
      check:
        config.engineApiWsEnabled
        config.wsEnabled
        config.engineApiEnabled == false
        config.rpcEnabled == false
        config.engineApiServerEnabled
        config.httpServerEnabled
        config.shareServerWithEngineApi

    test "json-rpc stay enabled when json-engine api enabled and using different port":
      let config = makeConfig(@["--rpc", "--engine-api", "--engine-api-port:8550", "--http-port:8545"])
      check:
        config.engineApiEnabled
        config.rpcEnabled
        config.engineApiWsEnabled == false
        config.wsEnabled == false
        config.httpServerEnabled
        config.engineApiServerEnabled
        config.shareServerWithEngineApi == false

    test "ws-rpc stay enabled when ws-engine api enabled and using different port":
      let config = makeConfig(@["--ws", "--engine-api-ws", "--engine-api-port:8551", "--http-port:8546"])
      check:
        config.engineApiWsEnabled
        config.wsEnabled
        config.engineApiEnabled == false
        config.rpcEnabled == false
        config.httpServerEnabled
        config.engineApiServerEnabled
        config.shareServerWithEngineApi == false

    test "ws, rpc, and engine api not enabled":
      let config = makeConfig(@[])
      check:
        config.engineApiWsEnabled == false
        config.wsEnabled == false
        config.engineApiEnabled == false
        config.rpcEnabled == false
        config.httpServerEnabled == false
        config.engineApiServerEnabled == false
        config.shareServerWithEngineApi == false

    let rng = newRng()
    test "net-key random":
      let config = makeConfig(@["--net-key:random"])
      check config.netKey == "random"
      let rc = rng[].getNetKeys(config.netKey)
      check rc.isOk

    test "net-key hex without 0x prefix":
      let config = makeConfig(@["--net-key:9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"])
      check config.netKey == "9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"
      let rc = rng[].getNetKeys(config.netKey)
      check rc.isOk
      let pkhex = rc.get.seckey.toRaw.to0xHex
      check pkhex == "0x9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"

    test "net-key hex with 0x prefix":
      let config = makeConfig(@["--net-key:0x9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"])
      check config.netKey == "0x9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"
      let rc = rng[].getNetKeys(config.netKey)
      check rc.isOk
      let pkhex = rc.get.seckey.toRaw.to0xHex
      check pkhex == "0x9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"

    test "net-key path":
      let config = makeConfig(@["--net-key:nimcache/key.txt"])
      check config.netKey == "nimcache/key.txt"
      let rc1 = rng[].getNetKeys(config.netKey)
      check rc1.isOk
      let pkhex1 = rc1.get.seckey.toRaw.to0xHex
      let rc2 = rng[].getNetKeys(config.netKey)
      check rc2.isOk
      let pkhex2 = rc2.get.seckey.toRaw.to0xHex
      check pkhex1 == pkhex2

    test "default key-store and default data-dir":
      let config = makeTestConfig()
      check config.keyStoreDir() == config.dataDir() / "keystore"

    test "custom key-store and custom data-dir":
      let config = makeConfig(@["--key-store:banana", "--data-dir:apple"])
      check config.keyStoreDir() == "banana"
      check config.dataDir() == "apple"

    test "default key-store and custom data-dir":
      let config = makeConfig(@["--data-dir:apple"])
      check config.dataDir() == "apple"
      check config.keyStoreDir() == "apple" / "keystore"

    test "custom key-store and default data-dir":
      let config = makeConfig(@["--key-store:banana"])
      check config.dataDir() == defaultDataDir("", "mainnet")
      check config.keyStoreDir() == "banana"

    test "loadKeystores missing address":
      var am = AccountsManager()
      let res = am.loadKeystores("tests/invalid_keystore/missingaddress")
      check res.isErr
      check res.error.find("no 'address' field in keystore data:") == 0

    test "loadKeystores not an object":
      var am = AccountsManager()
      let res = am.loadKeystores("tests/invalid_keystore/notobject")
      check res.isErr
      check res.error.find("expect json object of keystore data:") == 0

    test "TOML config file":
      let config = makeConfig(@["--config-file:tests/config_file/basic.toml"])
      check config.dataDir == "basic/data/dir"
      check config.era1DirFlag == some OutDir "basic/era1/dir"
      check config.eraDirFlag == some OutDir "basic/era/dir"
      check config.keyStoreDir == "basic/keystore"
      check config.importKey.string == "basic_import_key"
      check config.trustedSetupFile == some "basic_trusted_setup_file"
      check config.extraData == "basic_extra_data"
      check config.gasLimit == 5678
      check config.networkId == 777.u256
      check config.networkParams.config.isNil.not

      check config.logLevel == "DEBUG"
      check config.logFormat == StdoutLogKind.Json

      check config.metricsEnabled == true
      check config.metricsPort == 127.Port
      check config.metricsAddress == parseIpAddress("111.222.33.203")

      privateAccess(ExecutionClientConf)
      check config.bootstrapNodes.len == 3
      check config.bootstrapNodes[0] == "enode://d860a01f9722d78051619d1e2351aba3f43f943f6f00718d1b9baa4101932a1f5011f16bb2b1bb35db20d6fe28fa0bf09636d26a87d31de9ec6203eeedb1f666@18.138.108.67:30303"
      check config.bootstrapNodes[1] == "basic_bootstrap_file"
      check config.bootstrapNodes[2] == "enr:-IS4QHCYrYZbAKWCBRlAy5zzaDZXJBGkcnh4MHcBFZntXNFrdvJjX04jRzjzCBOonrkTfj499SZuOh8R33Ls8RRcy5wBgmlkgnY0gmlwhH8AAAGJc2VjcDI1NmsxoQPKY0yuDUmstAHYpMa2_oxVtw0RW_QAdpzBQA8yWM0xOIN1ZHCCdl8"

      check config.staticPeers.len == 3
      check config.staticPeers[0] == "enode://d860a01f9722d78051619d1e2351aba3f43f943f6f00718d1b9baa4101932a1f5011f16bb2b1bb35db20d6fe28fa0bf09636d26a87d31de9ec6203eeedb1f666@18.138.108.67:30303"
      check config.staticPeers[1] == "basic_static_peers_file"
      check config.staticPeers[2] == "enr:-IS4QHCYrYZbAKWCBRlAy5zzaDZXJBGkcnh4MHcBFZntXNFrdvJjX04jRzjzCBOonrkTfj499SZuOh8R33Ls8RRcy5wBgmlkgnY0gmlwhH8AAAGJc2VjcDI1NmsxoQPKY0yuDUmstAHYpMa2_oxVtw0RW_QAdpzBQA8yWM0xOIN1ZHCCdl8"

      check config.reconnectMaxRetry == 10
      check config.reconnectInterval == 11

      check config.listenAddress == parseIpAddress("123.124.125.34")
      check config.tcpPort == 5567.Port
      check config.udpPort == 8899.Port
      check config.maxPeers == 45
      check config.nat == NatConfig(hasExtIp: false, nat: NatAny)
      check config.discovery == ["V5"]
      check config.netKey == "random"
      check config.agentString == "basic_agent_string"

      check config.numThreads == 12
      check config.persistBatchSize == 32
      check config.rocksdbMaxOpenFiles == 33
      check config.rocksdbWriteBufferSize == 34
      check config.rocksdbRowCacheSize == 35
      check config.rocksdbBlockCacheSize == 36
      check config.rdbVtxCacheSize == 37
      check config.rdbKeyCacheSize == 38
      check config.rdbBranchCacheSize == 39
      check config.rdbPrintStats == true
      check config.rewriteDatadirId == true
      check config.eagerStateRootCheck ==  false

      check config.statelessProviderEnabled == true
      check config.statelessWitnessValidation == true

      check config.httpPort == 12788.Port
      check config.httpAddress == parseIpAddress("123.124.125.36")
      check config.rpcEnabled == true
      check config.rpcApi == ["eth", "admin"]
      check config.wsEnabled == true
      check config.wsApi  == ["eth", "admin"]
      check config.historyExpiry == false
      check config.historyExpiryLimit == some 1111'u64
      check config.portalUrl == "uri://what.org"

      check config.engineApiEnabled == true
      check config.engineApiPort == 12799.Port
      check config.engineApiAddress == parseIpAddress("123.124.125.37")
      check config.engineApiWsEnabled == true
      check config.allowedOrigins == ["*"]
      check config.jwtSecret.get.string == "basic_jwt_secret_file"

configurationMain()
