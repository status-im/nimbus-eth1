import eth/common, eth/trie/db, tables, algorithm, stew/byteutils

type
  KeyHash = array[32, byte]

  Multikeys = object
    hash: seq[KeyHash]

  Group = object
    a, b: int

proc toHash(x: string): KeyHash =
  let len = min(x.len, 32)
  for i in 0..<len:
    result[i] = x[i].byte

proc `$`(x: KeyHash): string =
  result = newString(x.len)
  for i, c in x:
    result[i] = c.char

let keys = [
  "abcdefghijklmnopqrstuv",
  "abcj34-09u3209u0jhfn93",
  "couynnm3mm,op312u0jnnm",
  "bad03he0823hhhf0hn1032",
  "abcdefghon0384hr0h3240",
  "baiju-94i-j2nh-9jdjlwk",
  "bai2222-9ur34nonf08hn3"
]


proc cmpHash(a, b: KeyHash): int =
  var i = 0
  var m = min(a.len, b.len)
  while i < m:
    result = a[i].int - b[i].int
    if result != 0: return
    inc(i)
  result = a.len - b.len

proc nextGroup(m: Multikeys, c: int, g: Group): Group =
  result.a = g.b + 1
  var head = m.hash[result.a][c]
  let last = m.hash.len - 1
  for i in result.a..<m.hash.len:
    if m.hash[i][c] != head:
      result.b = i - 1
      break
    elif i == last:
      result.b = last

proc lastGroup(a: Group, g: Group): bool =
  g.b == a.b

proc main() =
  var m: Multikeys
  for x in keys:
    m.hash.add toHash(x)

  m.hash.sort(cmpHash)

  for x in m.hash:
    echo x

  var a = Group(a: 0, b: m.hash.len - 1)
  var c = 0
  var g = Group(a: a.a-1, b: a.a-1)
  while not a.lastGroup(g):
    g = m.nextGroup(c, g)
    echo g

  echo "---"
  c = 2
  var b = Group(a: 3, b: 5)
  g = Group(a: b.a-1, b: b.a-1)
  while not  b.lastGroup(g):
     g = m.nextGroup(c, g)
     echo g
  
  
  echo "---"
  c = 2
  b = Group(a: 6, b: 6)
  g = Group(a: b.a-1, b: b.a-1)
  while not  b.lastGroup(g):
     g = m.nextGroup(c, g)
     echo g
  
main()
