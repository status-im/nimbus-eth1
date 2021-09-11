import
  std/[os],
  pkg/[unittest2, confutils],
  eth/[p2p, common],
  ../nimbus/[config, chain_config]

proc `==`(a, b: ChainId): bool =
  a.int == b.int

proc configurationMain*() =
  suite "configuration test suite":
    const genesisFile = "tests" / "customgenesis" / "calaveras.json"

    test "data-dir and key-store":
      let conf = makeConfig(@[]) # don't use makeConfig default cmdLine from inside all_tests
      check conf.dataDir.string == defaultDataDir()
      check conf.keyStore.string == defaultKeystoreDir()

      let cc = makeConfig(@["-d:apple\\bin", "-k:banana/bin"])
      check cc.dataDir.string == "apple\\bin"
      check cc.keyStore.string == "banana/bin"

      let dd = makeConfig(@["--data-dir:apple\\bin", "--key-store:banana/bin"])
      check dd.dataDir.string == "apple\\bin"
      check dd.keyStore.string == "banana/bin"

    test "prune-mode":
      let aa = makeConfig(@[])
      check aa.pruneMode == PruneMode.Full

      let bb = makeConfig(@["--prune-mode:full"])
      check bb.pruneMode == PruneMode.Full

      let cc = makeConfig(@["--prune-mode:archive"])
      check cc.pruneMode == PruneMode.Archive

      let dd = makeConfig(@["-p:archive"])
      check dd.pruneMode == PruneMode.Archive

    test "import":
      let aa = makeConfig(@[])
      check aa.importBlocks.string == ""

      let bb = makeConfig(@["--import-blocks:" & genesisFile])
      check bb.importBlocks.string == genesisFile

      let cc = makeConfig(@["-b:" & genesisFile])
      check cc.importBlocks.string == genesisFile

    test "network-id":
      let aa = makeConfig(@[])
      check aa.networkId.get() == MainNet
      check aa.mainnet == true
      check aa.customNetwork.get() == CustomNetwork()

      let conf = makeConfig(@["--custom-network:" & genesisFile, "--network-id:345"])
      check conf.networkId.get() == 345.NetworkId

    test "network-id first, custom-network next":
      let conf = makeConfig(@["--network-id:678", "--custom-network:" & genesisFile])
      check conf.networkId.get() == 678.NetworkId

    test "network-id not set, copy from chainId of customnetwork":
      let conf = makeConfig(@["--custom-network:" & genesisFile])
      check conf.networkId.get() == 123.NetworkId

    test "network-id not set, goerli set":
      let conf = makeConfig(@["--goerli"])
      check conf.networkId.get() == GoerliNet

    test "network-id set, goerli set":
      let conf = makeConfig(@["--goerli", "--network-id:123"])
      check conf.networkId.get() == GoerliNet

when isMainModule:
  configurationMain()
