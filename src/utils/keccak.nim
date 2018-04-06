import
  nimcrypto, strutils

#[
template keccak*(value: string): string =
  $keccak_256(value)

template keccak*(value: cstring): string =
  ($value).keccak
]#

proc keccak*(value: string): string =
  # TODO: Urgent - check this is doing the same thing as above
  var k = sha3_256()
  k.init
  k.update(cast[ptr uint8](value[0].unsafeaddr), value.len.uint)
  result = $finish(k)

