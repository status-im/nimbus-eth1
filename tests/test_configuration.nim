# Nimbus
# Copyright (c) 2019-2025 Status Research & Development GmbH
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
  ../execution_chain/[common, config],
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
      let conf = makeTestConfig()
      check conf.dataDir() == defaultDataDir("", "mainnet")
      check conf.keyStoreDir == defaultDataDir("", "mainnet") / "keystore"

      let cc = makeConfig(@["-d:apple\\bin", "-k:banana/bin"])
      check cc.dataDir() == "apple\\bin"
      check cc.keyStoreDir == "banana/bin"

      let dd = makeConfig(@["--data-dir:apple\\bin", "--key-store:banana/bin"])
      check dd.dataDir() == "apple\\bin"
      check dd.keyStoreDir == "banana/bin"

    test "import-rlp":
      let aa = makeTestConfig()
      check aa.cmd == NimbusCmd.noCommand

      let bb = makeConfig(@["import-rlp", genesisFile])
      check bb.cmd == NimbusCmd.`import-rlp`
      check bb.blocksFile[0].string == genesisFile

    test "network loading config file with no genesis data":
      # no genesis will fallback to geth compatibility mode
      let conf = makeConfig(@["--network:" & noGenesis])
      check conf.networkParams.genesis.isNil.not

    test "network loading config file with no 'config'":
      # no config will result in empty config, CommonRef keep working
      let conf = makeConfig(@["--network:" & noConfig])
      check conf.networkParams.config.isNil == false

    test "network-id":
      let aa = makeTestConfig()
      check aa.networkId == MainNet
      check aa.networkParams != NetworkParams()

      let conf = makeConfig(@["--network:" & genesisFile, "--network:345"])
      check conf.networkId == 345.u256

    test "network-id first, network next":
      let conf = makeConfig(@["--network:678", "--network:" & genesisFile])
      check conf.networkId == 678.u256

    test "network-id set, no network":
      let conf = makeConfig(@["--network:678"])
      check conf.networkId == 678.u256
      check conf.networkParams.genesis == Genesis()
      check conf.networkParams.config == ChainConfig()

    test "network-id not set, copy from chainId of custom network":
      let conf = makeConfig(@["--network:" & genesisFile])
      check conf.networkId == 123.u256

    test "network-id not set, sepolia set":
      let conf = makeConfig(@["--network:sepolia"])
      check conf.networkId == SepoliaNet

    test "network-id set, sepolia set":
      let conf = makeConfig(@["--network:sepolia", "--network:123"])
      check conf.networkId == 123.u256

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

      let dd = makeConfig(@["--rpc-api:admin"])
      let dx = dd.getRpcFlags()
      check { RpcFlag.Admin } == dx

      let ee = makeConfig(@["--rpc-api:eth,admin"])
      let ex = ee.getRpcFlags()
      check { RpcFlag.Eth, RpcFlag.Admin } == ex

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

    test "--bootstrap-node and --bootstrap-file":
      let conf = makeTestConfig()
      let bootnodes = conf.getBootstrapNodes()
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
      let conf = makeTestConfig()
      check conf.getStaticPeers().enodes.len == 0

      let aa = makeConfig(@["--static-peers:" & bootNode])
      check aa.getStaticPeers().enodes.len == 1

      let bb = makeConfig(@["--static-peers:" & bootNode & "," & bootNode])
      check bb.getStaticPeers().enodes.len == 2

      let cc = makeConfig(@["--static-peers:" & bootNode, "--static-peers:" & bootNode])
      check cc.getStaticPeers().enodes.len == 2

    test "chainId of network is oneof std network":
      const
        chainid1 = "tests" / "customgenesis" / "chainid1.json"

      let conf = makeConfig(@["--network:" & chainid1])
      check conf.networkId == 1.u256
      check conf.networkParams.config.londonBlock.get() == 1337
      check conf.getBootstrapNodes().enodes.len == 0

    test "json-rpc enabled when json-engine api enabled and share same port":
      let conf = makeConfig(@["--engine-api", "--engine-api-port:8545", "--http-port:8545"])
      check:
        conf.engineApiEnabled == true
        conf.rpcEnabled == false
        conf.wsEnabled == false
        conf.engineApiWsEnabled == false
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
        conf.httpServerEnabled
        conf.engineApiServerEnabled
        conf.shareServerWithEngineApi == false

    test "ws, rpc, and engine api not enabled":
      let conf = makeConfig(@[])
      check:
        conf.engineApiWsEnabled == false
        conf.wsEnabled == false
        conf.engineApiEnabled == false
        conf.rpcEnabled == false
        conf.httpServerEnabled == false
        conf.engineApiServerEnabled == false
        conf.shareServerWithEngineApi == false

    let rng = newRng()
    test "net-key random":
      let conf = makeConfig(@["--net-key:random"])
      check conf.netKey == "random"
      let rc = rng[].getNetKeys(conf.netKey)
      check rc.isOk

    test "net-key hex without 0x prefix":
      let conf = makeConfig(@["--net-key:9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"])
      check conf.netKey == "9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"
      let rc = rng[].getNetKeys(conf.netKey)
      check rc.isOk
      let pkhex = rc.get.seckey.toRaw.to0xHex
      check pkhex == "0x9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"

    test "net-key hex with 0x prefix":
      let conf = makeConfig(@["--net-key:0x9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"])
      check conf.netKey == "0x9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"
      let rc = rng[].getNetKeys(conf.netKey)
      check rc.isOk
      let pkhex = rc.get.seckey.toRaw.to0xHex
      check pkhex == "0x9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"

    test "net-key path":
      let conf = makeConfig(@["--net-key:nimcache/key.txt"])
      check conf.netKey == "nimcache/key.txt"
      let rc1 = rng[].getNetKeys(conf.netKey)
      check rc1.isOk
      let pkhex1 = rc1.get.seckey.toRaw.to0xHex
      let rc2 = rng[].getNetKeys(conf.netKey)
      check rc2.isOk
      let pkhex2 = rc2.get.seckey.toRaw.to0xHex
      check pkhex1 == pkhex2

    test "default key-store and default data-dir":
      let conf = makeTestConfig()
      check conf.keyStoreDir() == conf.dataDir() / "keystore"

    test "custom key-store and custom data-dir":
      let conf = makeConfig(@["--key-store:banana", "--data-dir:apple"])
      check conf.keyStoreDir() == "banana"
      check conf.dataDir() == "apple"

    test "default key-store and custom data-dir":
      let conf = makeConfig(@["--data-dir:apple"])
      check conf.dataDir() == "apple"
      check conf.keyStoreDir() == "apple" / "keystore"

    test "custom key-store and default data-dir":
      let conf = makeConfig(@["--key-store:banana"])
      check conf.dataDir() == defaultDataDir("", "mainnet")
      check conf.keyStoreDir() == "banana"

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
      let conf = makeConfig(@["--config-file:tests/config_file/basic.toml"])
      check conf.dataDir == "basic/data/dir"
      check conf.era1DirFlag == some OutDir "basic/era1/dir"
      check conf.eraDirFlag == some OutDir "basic/era/dir"
      check conf.keyStoreDir == "basic/keystore"
      check conf.importKey.string == "basic_import_key"
      check conf.trustedSetupFile == some "basic_trusted_setup_file"
      check conf.extraData == "basic_extra_data"
      check conf.gasLimit == 5678
      check conf.networkId == 777.u256
      check conf.networkParams.config.isNil.not

      check conf.logLevel == "DEBUG"
      check conf.logStdout == StdoutLogKind.Json

      check conf.metricsEnabled == true
      check conf.metricsPort == 127.Port
      check conf.metricsAddress == parseIpAddress("111.222.33.203")

      privateAccess(NimbusConf)
      check conf.bootstrapNodes.len == 3
      check conf.bootstrapNodes[0] == "enode://d860a01f9722d78051619d1e2351aba3f43f943f6f00718d1b9baa4101932a1f5011f16bb2b1bb35db20d6fe28fa0bf09636d26a87d31de9ec6203eeedb1f666@18.138.108.67:30303"
      check conf.bootstrapNodes[1] == "basic_bootstrap_file"
      check conf.bootstrapNodes[2] == "enr:-IS4QHCYrYZbAKWCBRlAy5zzaDZXJBGkcnh4MHcBFZntXNFrdvJjX04jRzjzCBOonrkTfj499SZuOh8R33Ls8RRcy5wBgmlkgnY0gmlwhH8AAAGJc2VjcDI1NmsxoQPKY0yuDUmstAHYpMa2_oxVtw0RW_QAdpzBQA8yWM0xOIN1ZHCCdl8"

      check conf.staticPeers.len == 3
      check conf.staticPeers[0] == "enode://d860a01f9722d78051619d1e2351aba3f43f943f6f00718d1b9baa4101932a1f5011f16bb2b1bb35db20d6fe28fa0bf09636d26a87d31de9ec6203eeedb1f666@18.138.108.67:30303"
      check conf.staticPeers[1] == "basic_static_peers_file"
      check conf.staticPeers[2] == "enr:-IS4QHCYrYZbAKWCBRlAy5zzaDZXJBGkcnh4MHcBFZntXNFrdvJjX04jRzjzCBOonrkTfj499SZuOh8R33Ls8RRcy5wBgmlkgnY0gmlwhH8AAAGJc2VjcDI1NmsxoQPKY0yuDUmstAHYpMa2_oxVtw0RW_QAdpzBQA8yWM0xOIN1ZHCCdl8"

      check conf.reconnectMaxRetry == 10
      check conf.reconnectInterval == 11

      check conf.listenAddress == parseIpAddress("123.124.125.34")
      check conf.tcpPort == 5567.Port
      check conf.udpPort == 8899.Port
      check conf.maxPeers == 45
      check conf.nat == NatConfig(hasExtIp: false, nat: NatAny)
      check conf.discovery == ["V5"]
      check conf.netKey == "random"
      check conf.agentString == "basic_agent_string"

      check conf.numThreads == 12
      check conf.persistBatchSize == 32
      check conf.rocksdbMaxOpenFiles == 33
      check conf.rocksdbWriteBufferSize == 34
      check conf.rocksdbRowCacheSize == 35
      check conf.rocksdbBlockCacheSize == 36
      check conf.rdbVtxCacheSize == 37
      check conf.rdbKeyCacheSize == 38
      check conf.rdbBranchCacheSize == 39
      check conf.rdbPrintStats == true
      check conf.rewriteDatadirId == true
      check conf.eagerStateRootCheck ==  false

      check conf.statelessProviderEnabled == true
      check conf.statelessWitnessValidation == true

      check conf.httpPort == 12788.Port
      check conf.httpAddress == parseIpAddress("123.124.125.36")
      check conf.rpcEnabled == true
      check conf.rpcApi == ["eth", "admin"]
      check conf.wsEnabled == true
      check conf.wsApi  == ["eth", "admin"]
      check conf.historyExpiry == false
      check conf.historyExpiryLimit == some 1111'u64
      check conf.portalUrl == "uri://what.org"

      check conf.engineApiEnabled == true
      check conf.engineApiPort == 12799.Port
      check conf.engineApiAddress == parseIpAddress("123.124.125.37")
      check conf.engineApiWsEnabled == true
      check conf.allowedOrigins == ["*"]
      check conf.jwtSecret.get.string == "basic_jwt_secret_file"

configurationMain()
