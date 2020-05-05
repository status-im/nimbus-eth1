import
  eth/common, eth/trie/[db, nibbles], algorithm, stew/byteutils,
  ./witness_types

type
  KeyHash = array[32, byte]
  StorageSlot = array[32, byte]

  KeyData = object
    visited: bool
    hash: KeyHash
    case storageMode: bool
    of true:
      storageSlot: StorageSlot
    of false:
      storageKeys: MultikeysRef
      address: EthAddress

  Multikeys* = object
    keys: seq[KeyData]

  MultikeysRef* = ref Multikeys

  Group* = object
    first, last: int16

  BranchGroup* = object
    mask*: uint
    groups*: array[16, Group]

  AccountKey* = tuple[address: EthAddress, storageKeys: MultikeysRef]
  MatchGroup* = tuple[match: bool, group: Group]

func cmpHash(a, b: KeyHash): int =
  var i = 0
  var m = min(a.len, b.len)
  while i < m:
    result = a[i].int - b[i].int
    if result != 0: return
    inc(i)
  result = a.len - b.len

func cmpHash(a, b: KeyData): int =
  cmpHash(a.hash, b.hash)

func getNibble(x: openArray[byte], i: int): byte =
  if(i and 0x01) == 0x01:
    result = x[i shr 1] and 0x0F
  else:
    result = x[i shr 1] shr 4

func compareNibbles(x: openArray[byte], start: int, n: NibblesSeq): bool =
  var i = 0
  while i < n.len:
    if getNibble(x, start + i) != n[i]:
      return false
    inc i
  result = true

func `$`(x: KeyHash): string =
  toHex(x)

proc newMultiKeys*(keys: openArray[AccountKey]): MultikeysRef =
  result = new Multikeys
  result.keys = newSeq[KeyData](keys.len)
  for i, a in keys:
    result.keys[i] = KeyData(
      storageMode: false,
      hash: keccak(a.address).data,
      address: a.address,
      storageKeys: a.storageKeys)
  result.keys.sort(cmpHash)

proc newMultiKeys*(keys: openArray[StorageSlot]): MultikeysRef =
  result = new Multikeys
  result.keys = newSeq[KeyData](keys.len)
  for i, a in keys:
    result.keys[i] = KeyData(storageMode: true, hash: keccak(a).data, storageSlot: a)
  result.keys.sort(cmpHash)

func initGroup*(m: MultikeysRef): Group =
  result = Group(first: 0'i16, last: (m.keys.len - 1).int16)

func groups*(m: MultikeysRef, parentGroup: Group, depth: int): BranchGroup =
  # similar to a branch node, the product of this func
  # is a 16 bits bitmask and an array of max 16 groups
  # if the bit is set, the n-th elem of array have a group
  # each group consist of at least one key
  var g = Group(first: parentGroup.first, last: parentGroup.first)
  var nibble = getNibble(m.keys[g.first].hash, depth)
  let last = parentGroup.last
  for i in parentGroup.first..parentGroup.last:
    let currNibble = getNibble(m.keys[i].hash, depth)
    if currNibble != nibble:
      g.last = i - 1
      setBranchMaskBit(result.mask, nibble.int)
      result.groups[nibble.int] = g
      nibble = currNibble
      g.first = i
    if i == last:
      g.last = last
      setBranchMaskBit(result.mask, nibble.int)
      result.groups[nibble.int] = g

iterator groups*(m: MultikeysRef, depth: int, n: NibblesSeq, parentGroup: Group): MatchGroup =
  # using common-prefix comparison, this iterator
  # will produce groups, usually only one match group
  # the rest will be not match
  # in case of wrong path, there will be no match at all
  var g = Group(first: parentGroup.first, last: parentGroup.first)
  var match = compareNibbles(m.keys[g.first].hash, depth, n)
  let last = parentGroup.last
  var haveGroup = false
  var groupResult: Group
  var matchResult: bool
  for i in parentGroup.first..parentGroup.last:
    if compareNibbles(m.keys[i].hash, depth, n) != match:
      g.last = i - 1
      haveGroup = true
      matchResult = match
      groupResult = g
      match = not match
      g = Group(first: g.last, last: g.last)
    if i == last:
      haveGroup = true
      g.last = last
      groupResult = g
      matchResult = match
    if haveGroup:
      haveGroup = false
      yield (matchResult, groupResult)

when isMainModule:
  let keys = [
    (hexToByteArray[20]("abcdef0a0b0c0d0e0f1234567890aabbccddeeff"), MultikeysRef(nil)),
    (hexToByteArray[20]("abc0000000000000000000000000000000000000"), MultikeysRef(nil)),
    (hexToByteArray[20]("cde9769bbcbdef9880932852388bdceabcdeadea"), MultikeysRef(nil)),
    (hexToByteArray[20]("bad03eaeaea69072375281381267397182bcdbef"), MultikeysRef(nil)),
    (hexToByteArray[20]("abcdefbbbbbbdddeefffaaccee19826736134298"), MultikeysRef(nil)),
    (hexToByteArray[20]("ba88888888dddddbbbbfffeeeccaa78128301389"), MultikeysRef(nil)),
    (hexToByteArray[20]("ba9084097472374372327238bbbcdffecadfecf3"), MultikeysRef(nil))
  ]

  proc main() =
    var m = newMultikeys(keys)

    for x in m.keys:
      echo x.hash

    var parentGroup = m.initGroup()
    var depth = 3
    var bg = m.groups(parentGroup, depth)

    for i in 0..<16:
      if branchMaskBitIsSet(bg.mask, i):
        echo bg.groups[i]

    var p = Group(first: 0, last: 2)
    var n = hexToByteArray[1]("1F")
    for j in groups(m, 3, initNibbleRange(n), p):
      debugEcho j

  main()
