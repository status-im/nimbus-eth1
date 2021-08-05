import
  std/[os, parseopt],
  unittest2, stew/byteutils,
  eth/common/eth_types,
  eth/p2p,
  ../nimbus/vm_internals,
  ../nimbus/config

func toAddress(n: int): EthAddress =
  result[19] = n.byte

func toAddress(a, b: int): EthAddress =
  result[18] = a.byte
  result[19] = b.byte

func toAddress(a, b, c: int): EthAddress =
  result[17] = a.byte
  result[18] = b.byte
  result[19] = c.byte

proc miscMain*() =
  suite "Misc test suite":
    test "EthAddress to int":
      check toAddress(0xff).toInt == 0xFF
      check toAddress(0x10, 0x0).toInt == 0x1000
      check toAddress(0x10, 0x0, 0x0).toInt == 0x100000

    const genesisFile = "tests" / "customgenesis" / "calaveras.json"
    test "networkid cli":
      var msg: string
      var opt = initOptParser("--customnetwork:" & genesisFile & " --networkid:123")
      let res = processArguments(msg, opt)
      if res != Success:
        echo msg
        quit(QuitFailure)

      let conf = getConfiguration()
      check conf.net.networkId == 123.NetworkId

    test "networkid first, customnetwork next":
      var msg: string
      var opt = initOptParser(" --networkid:123 --customnetwork:" & genesisFile)
      let res = processArguments(msg, opt)
      if res != Success:
        echo msg
        quit(QuitFailure)

      let conf = getConfiguration()
      check conf.net.networkId == 123.NetworkId

when isMainModule:
  miscMain()
