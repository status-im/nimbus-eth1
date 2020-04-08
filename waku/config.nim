import
  confutils/defs, chronicles, chronos,
  eth/keys, eth/p2p/rlpx_protocols/waku_protocol

type
  Fleet* =  enum
    none
    prod
    staging
    test

  WakuNodeConf* = object
    logLevel* {.
      desc: "Sets the log level."
      defaultValue: LogLevel.INFO
      name: "log-level" }: LogLevel

    tcpPort* {.
      desc: "TCP listening port."
      defaultValue: 30303
      name: "tcp-port" }: uint16

    udpPort* {.
      desc: "UDP listening port."
      defaultValue: 30303
      name: "udp-port" }: uint16

    portsShift* {.
      desc: "Add a shift to all port numbers."
      defaultValue: 0
      name: "ports-shift" }: uint16

    nat* {.
      desc: "Specify method to use for determining public address. " &
            "Must be one of: any, none, upnp, pmp, extip:<IP>."
      defaultValue: "any" }: string

    discovery* {.
      desc: "Enable/disable discovery v4."
      defaultValue: true
      name: "discovery" }: bool

    noListen* {.
      desc: "Disable listening for incoming peers."
      defaultValue: false
      name: "no-listen" }: bool

    fleet* {.
      desc: "Select the fleet to connect to."
      defaultValue: Fleet.none
      name: "fleet" }: Fleet

    bootnodes* {.
      desc: "Enode URL to bootstrap P2P discovery with. Argument may be repeated."
      name: "bootnode" }: seq[string]

    staticnodes* {.
      desc: "Enode URL to directly connect with. Argument may be repeated."
      name: "staticnode" }: seq[string]

    whisper* {.
      desc: "Enable the Whisper protocol."
      defaultValue: false
      name: "whisper" }: bool

    whisperBridge* {.
      desc: "Enable the Whisper protocol and bridge with Waku protocol."
      defaultValue: false
      name: "whisper-bridge" }: bool

    lightNode* {.
      desc: "Run as light node (no message relay).",
      defaultValue: false
      name: "light-node" }: bool

    wakuTopicInterest* {.
      desc: "Run as node with a topic-interest",
      defaultValue: false
      name: "waku-topic-interest" }: bool

    wakuPow* {.
      desc: "PoW requirement of Waku node.",
      defaultValue: 0.002
      name: "waku-pow" }: float64

    nodekey* {.
      desc: "P2P node private key as hex.",
      defaultValue: KeyPair.random().tryGet()
      name: "nodekey" }: KeyPair
    # TODO: Add nodekey file option

    bootnodeOnly* {.
      desc: "Run only as discovery bootnode."
      defaultValue: false
      name: "bootnode-only" }: bool

    rpc* {.
      desc: "Enable Waku RPC server.",
      defaultValue: false
      name: "rpc" }: bool

    rpcAddress* {.
      desc: "Listening address of the RPC server.",
      defaultValue: parseIpAddress("127.0.0.1")
      name: "rpc-address" }: IpAddress

    rpcPort* {.
      desc: "Listening port of the RPC server.",
      defaultValue: 8545
      name: "rpc-port" }: uint16

    metricsServer* {.
      desc: "Enable the metrics server."
      defaultValue: false
      name: "metrics-server" }: bool

    metricsServerAddress* {.
      desc: "Listening address of the metrics server."
      defaultValue: parseIpAddress("127.0.0.1")
      name: "metrics-server-address" }: IpAddress

    metricsServerPort* {.
      desc: "Listening HTTP port of the metrics server."
      defaultValue: 8008
      name: "metrics-server-port" }: uint16

    logMetrics* {.
      desc: "Enable metrics logging."
      defaultValue: false
      name: "log-metrics" }: bool

    # TODO:
    # - discv5 + topic register
    # - mailserver functionality

proc parseCmdArg*(T: type KeyPair, p: TaintedString): T =
  try:
    # TODO: add isValidPrivateKey check from Nimbus?
    result.seckey = PrivateKey.fromHex(string(p)).tryGet()
    result.pubkey = result.seckey.toPublicKey()[]
  except CatchableError as e:
    raise newException(ConfigurationError, "Invalid private key")

proc completeCmdArg*(T: type KeyPair, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg*(T: type IpAddress, p: TaintedString): T =
  try:
    result = parseIpAddress(p)
  except CatchableError as e:
    raise newException(ConfigurationError, "Invalid IP address")

proc completeCmdArg*(T: type IpAddress, val: TaintedString): seq[string] =
  return @[]
