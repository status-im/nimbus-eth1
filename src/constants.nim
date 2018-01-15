
import
  math, strutils, tables #, eth_utils

type
  TypeHint* {.pure.} = enum UInt256, Bytes, Any

  Int256* = distinct int # TODO

proc `>`*(a: Int256, b: Int256): bool =
  a.int > b.int

proc `<`*(a: Int256, b: Int256): bool =
  a.int < b.int

proc `$`*(a: Int256): string =
  $(a.int)

# proc `-`*(a: Int256, b: Int256): Int256 {.borrow.}

# proc `+`*(a: Int256, b: Int256): Int256 {.borrow.}

# proc `-=`*(a: var Int256, b: Int256) {.borrow.}

# proc `+=`*(a: var Int256, b: Int256) {.borrow.}

proc `-`*(a: Int256, b: Int256): Int256 =
  (a.int - b.int).Int256

proc `+`*(a: Int256, b: Int256): Int256 =
  (a.int + b.int).Int256

proc `-=`*(a: var Int256, b: Int256) =
  a = (a - b).Int256

proc `+=`*(a: var Int256, b: Int256) =
  a = (a + b).Int256

proc repeat(b: cstring, count: int): cstring =
  # TODO: faster
  var s = $b
  result = cstring(repeat(s, count))

const
  # UINT256MAX = 2 ^ 256 - 1
  # UINT256CEILING = 2 ^ 256
  # UINT255MAX = 2 ^ 255 - 1
  # UINT255CEILING = 2 ^ 255
  NULLBYTE = cstring"\\x00"
  EMPTYWORD = repeat(NULLBYTE, 32)
  # UINT160CEILING = 2 ^ 160
  CREATE_CONTRACT_ADDRESS* = cstring""
  ZEROADDRESS = repeat(cstring"\\x00", 20)
  ZEROHASH32 = repeat(cstring"\\x00", 20)
  STACKDEPTHLIMIT = 1024
  GASNULL = 0
  GASZERO = 0
  GASBASE = 2
  GASVERYLOW = 3
  GASLOW = 5
  GASMID = 8
  GASHIGH = 10
  GASEXTCODE = 20
  GASBALANCE = 20
  GASSLOAD = 50
  GASJUMPDEST = 1
  GASSSET = 20000
  GASSRESET = 5000
  REFUNDSCLEAR = 15000
  GASSELFDESTRUCT = 0
  GASSELFDESTRUCTNEWACCOUNT = 25000
  GASCREATE = 32000
  GASCALL = 40
  GASCALLVALUE = 9000
  GASCALLSTIPEND = 2300
  GASNEWACCOUNT = 25000
  GASEXP = 10
  GASEXPBYTE = 10
  GASMEMORY = 3
  GASTXCREATE = 32000
  GASTXDATAZERO = 4
  GASTXDATANONZERO = 68
  GASTX = 21000
  GASLOG = 375
  GASLOGDATA = 8
  GASLOGTOPIC = 375
  GASSHA3 = 30
  GASSHA3WORD = 6
  GASCOPY = 3
  GASBLOCKHASH = 20
  GASCODEDEPOSIT = 200
  GASMEMORYQUADRATICDENOMINATOR = 512
  GASSHA256 = 60
  GASSHA256WORD = 12
  GASRIPEMD160 = 600
  GASRIPEMD160WORD = 120
  GASIDENTITY = 15
  GASIDENTITYWORD = 3
  GASECRECOVER = 3000
  GASECADD = 500
  GASECMUL = 40000
  GASECPAIRINGBASE = 100000
  GASECPAIRINGPERPOINT = 80000
  GASLIMITEMADENOMINATOR = 1024
  GASLIMITADJUSTMENTFACTOR = 1024
  GASLIMITMINIMUM = 5000
  # GASLIMITMAXIMUM = 2 ^ 63 - 1
  GASLIMITUSAGEADJUSTMENTNUMERATOR = 3
  GASLIMITUSAGEADJUSTMENTDENOMINATOR = 2
  DIFFICULTYADJUSTMENTDENOMINATOR = 2048
  DIFFICULTYMINIMUM = 131072
  BOMBEXPONENTIALPERIOD = 100000
  # BOMBEXPONENTIALFREEPERIODS = 2
  # BLOCKREWARD = 5 * denoms.ether
  UNCLEDEPTHPENALTYFACTOR = 8
  MAXUNCLEDEPTH = 6
  MAXUNCLES = 2
  # SECPK1P = 2 ^ 256 - 2 ^ 32 - 977
  SECPK1N = 0
  SECPK1A = 0
  SECPK1B = 7
  SECPK1Gx = 0
  SECPK1Gy = 0
  SECPK1G = (SECPK1Gx, SECPK1Gy)
  EMPTYUNCLEHASH = cstring"\\x1d\\xccM\\xe8\\xde\\xc7]z\\xab\\x85\\xb5g\\xb6\\xcc\\xd4\\x1a\\xd3\\x12E\\x1b\\x94\\x8at\\x13\\xf0\\xa1B\\xfd@\\xd4\\x93G"
  GENESISBLOCKNUMBER = 0
  GENESISDIFFICULTY = 131072
  GENESISGASLIMIT = 3141592
  GENESISPARENTHASH = ZEROHASH32
  GENESISCOINBASE = ZEROADDRESS
  GENESISNONCE = cstring"\\x00\\x00\\x00\\x00\\x00\\x00\\x00B"
  GENESISMIXHASH = ZEROHASH32
  EMPTYSHA3 = cstring"\\xc5\\xd2F\\x01\\x86\\xf7#<\\x92~}\\xb2\\xdc\\xc7\\x03\\xc0\\xe5\\x00\\xb6S\\xca\\x82';{\\xfa\\xd8\\x04]\\x85\\xa4p"
  BLANKROOTHASH = cstring"V\\xe8\\x1f\\x17\\x1b\\xccU\\xa6\\xff\\x83E\\xe6\\x92\\xc0\\xf8n[H\\xe0\\x1b\\x99l\\xad\\xc0\\x01b/\\xb5\\xe3c\\xb4!"
  GASMODEXPQUADRATICDENOMINATOR = 20
  MAXPREVHEADERDEPTH = 256
