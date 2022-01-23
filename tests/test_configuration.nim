import
  std/[os],
  pkg/[unittest2, confutils],
  eth/[p2p, common],
  ../nimbus/[config, chain_config],
  ./test_helpers

proc `==`(a, b: ChainId): bool =
  a.int == b.int

proc configurationMain*() =
  suite "configuration test suite":
    const
      genesisFile = "tests" / "customgenesis" / "calaveras.json"
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

    test "prune-mode":
      let aa = makeTestConfig()
      check aa.pruneMode == PruneMode.Full

      let bb = makeConfig(@["--prune-mode:full"])
      check bb.pruneMode == PruneMode.Full

      let cc = makeConfig(@["--prune-mode:archive"])
      check cc.pruneMode == PruneMode.Archive

      let dd = makeConfig(@["-p:archive"])
      check dd.pruneMode == PruneMode.Archive

    test "import":
      let aa = makeTestConfig()
      check aa.cmd == NimbusCmd.noCommand

      let bb = makeConfig(@["import", genesisFile])
      check bb.cmd == NimbusCmd.`import`
      check bb.blocksFile.string == genesisFile

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
      check conf.networkParams == NetworkParams()

    test "network-id not set, copy from chainId of custom network":
      let conf = makeConfig(@["--custom-network:" & genesisFile])
      check conf.networkId == 123.NetworkId

    test "network-id not set, goerli set":
      let conf = makeConfig(@["--network:goerli"])
      check conf.networkId == GoerliNet

    test "network-id set, goerli set":
      let conf = makeConfig(@["--network:goerli", "--network:123"])
      check conf.networkId == 123.NetworkId

    test "rpc-api":
      let conf = makeTestConfig()
      let flags = conf.getRpcFlags()
      check RpcFlag.Eth in flags

      let aa = makeConfig(@["--rpc-api:eth"])
      let ax = aa.getRpcFlags()
      check RpcFlag.Eth in ax

      let bb = makeConfig(@["--rpc-api:eth", "--rpc-api:debug"])
      let bx = bb.getRpcFlags()
      check RpcFlag.Eth in bx
      check RpcFlag.Debug in bx

      let cc = makeConfig(@["--rpc-api:eth,debug"])
      let cx = cc.getRpcFlags()
      check RpcFlag.Eth in cx
      check RpcFlag.Debug in cx

    test "ws-api":
      let conf = makeTestConfig()
      let flags = conf.getWsFlags()
      check RpcFlag.Eth in flags

      let aa = makeConfig(@["--ws-api:eth"])
      let ax = aa.getWsFlags()
      check RpcFlag.Eth in ax

      let bb = makeConfig(@["--ws-api:eth", "--ws-api:debug"])
      let bx = bb.getWsFlags()
      check RpcFlag.Eth in bx
      check RpcFlag.Debug in bx

      let cc = makeConfig(@["--ws-api:eth,debug"])
      let cx = cc.getWsFlags()
      check RpcFlag.Eth in cx
      check RpcFlag.Debug in cx

    test "protocols":
      let conf = makeTestConfig()
      let flags = conf.getProtocolFlags()
      check ProtocolFlag.Eth in flags

      let aa = makeConfig(@["--protocols:les"])
      let ax = aa.getProtocolFlags()
      check ProtocolFlag.Les in ax

      let bb = makeConfig(@["--protocols:eth", "--protocols:les"])
      let bx = bb.getProtocolFlags()
      check ProtocolFlag.Eth in bx
      check ProtocolFlag.Les in bx

      let cc = makeConfig(@["--protocols:eth,les"])
      let cx = cc.getProtocolFlags()
      check ProtocolFlag.Eth in cx
      check ProtocolFlag.Les in cx

    test "bootstrap-node and bootstrap-file":
      let conf = makeTestConfig()
      let bootnodes = conf.getBootnodes()
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
      check conf.networkParams.config.londonBlock == 1337
      check conf.getBootnodes().len == 0

when isMainModule:
  configurationMain()
