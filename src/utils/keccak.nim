import
  keccak_tiny, strutils

template keccak*(value: string): string =
  $keccak_256(value)

template keccak*(value: cstring): string =
  ($value).keccak
