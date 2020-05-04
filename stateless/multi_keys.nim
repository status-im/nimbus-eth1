import
  eth/common, eth/trie/[db, nibbles], algorithm, stew/byteutils,
  ./witness_types

type
  KeyHash = array[32, byte]

  HashAddress = object
    visited: bool
    hash: KeyHash
    address: EthAddress

  Multikeys* = object
    keys: seq[HashAddress]

  Group* = object
    a, b: int16

  BranchGroup* = object
    mask*: uint
    groups*: array[16, Group]

  GroupNibble = object
    nibble: byte
    group: Group

func cmpHash(a, b: KeyHash): int =
  var i = 0
  var m = min(a.len, b.len)
  while i < m:
    result = a[i].int - b[i].int
    if result != 0: return
    inc(i)
  result = a.len - b.len

func cmpHash(a, b: HashAddress): int =
  cmpHash(a.hash, b.hash)

proc initMultiKeys*(addrs: openArray[EthAddress]): Multikeys =
  result.keys = newSeq[HashAddress](addrs.len)
  for i, a in addrs:
    result.keys[i] = HashAddress(hash: keccak(a).data, address: a)
  result.keys.sort(cmpHash)

func `$`(x: KeyHash): string =
  toHex(x)

func initGroup*(m: Multikeys): Group =
  result = Group(a: 0'i16, b: (m.keys.len - 1).int16)

func initChildGroup(a: Group): Group =
  result = Group(a: a.a-1'i16, b: a.a-1'i16)

func getNibble(x: openArray[byte], i: int): byte =
  if(i and 0x01) == 0x01:
    result = x[i shr 1] and 0x0F
  else:
    result = x[i shr 1] shr 4

func nextGroup(m: Multikeys, depth: int, g: Group): GroupNibble =
  result.group.a = g.b + 1
  result.nibble = getNibble(m.keys[result.group.a].hash, depth)
  let last = (m.keys.len - 1).int16
  for i in result.group.a..<m.keys.len.int16:
    if getNibble(m.keys[i].hash, depth) != result.nibble:
      result.group.b = i - 1
      break
    elif i == last:
      result.group.b = last

func lastGroup(a: Group, g: Group): bool =
  a.b == g.b

func compareNibbles(x: openArray[byte], start: int, n: NibblesSeq): bool =
  var i = 0
  while i < n.len:
    if getNibble(x, start + i) != n[i]:
      return false
    inc i
  result = true

func groups*(m: Multikeys, parentGroup: Group, depth: int): BranchGroup =
  # similar to a branch node, the product of this func
  # is a 16 bits bitmask and an array of max 16 groups
  # if the bit is set, the n-th elem of array have a group
  # each group consist of at least one key
  var gn = GroupNibble(group: parentGroup.initChildGroup())
  while not parentGroup.lastGroup(gn.group):
    gn = m.nextGroup(depth, gn.group)
    setBranchMaskBit(result.mask, gn.nibble.int)
    result.groups[gn.nibble.int] = gn.group

iterator groups*(m: Multikeys, depth: int, n: NibblesSeq, parentGroup: Group): (bool, Group) =
  # using common-prefix comparison, this iterator
  # will produce groups, usually only one match group
  # the rest will be not match
  # in case of wrong path, there will be no match at all
  var g = Group(a: parentGroup.a, b: parentGroup.a)
  var match = compareNibbles(m.keys[g.a].hash, depth, n)
  let last = parentGroup.b
  var haveMatch = false
  var matchG: Group
  var matchB: bool
  for i in parentGroup.a..parentGroup.b:
    if compareNibbles(m.keys[i].hash, depth, n) == match:
      inc g.b
    else:
      haveMatch = true
      matchB = match
      matchG = g
      match = not match
      g = Group(a: g.b, b: g.b)
    if i == last:
      haveMatch = true
      g.b = last
      matchG = g
      matchB = match
    if haveMatch:
      haveMatch = false
      yield (matchB, matchG)

let keys = [
  hexToByteArray[20]("abcdef0a0b0c0d0e0f1234567890aabbccddeeff"),
  hexToByteArray[20]("abc0000000000000000000000000000000000000"),
  hexToByteArray[20]("cde9769bbcbdef9880932852388bdceabcdeadea"),
  hexToByteArray[20]("bad03eaeaea69072375281381267397182bcdbef"),
  hexToByteArray[20]("abcdefbbbbbbdddeefffaaccee19826736134298"),
  hexToByteArray[20]("ba88888888dddddbbbbfffeeeccaa78128301389"),
  hexToByteArray[20]("ba9084097472374372327238bbbcdffecadfecf3")
]

proc main() =
  var m = initMultikeys(keys)

  for x in m.keys:
    echo x.hash

  var parentGroup = m.initGroup()
  var depth = 1
  var bg = m.groups(parentGroup, depth)

  for i in 0..<16:
    if branchMaskBitIsSet(bg.mask, i):
      echo bg.groups[i]

  var p = Group(a: 0, b: 2)
  var n = hexToByteArray[2]("cdef")
  for j in groups(m, 2, initNibbleRange(n), p):
    debugEcho j

main()
