import
  keccak_tiny, strutils

template keccak*(value: string): cstring =
  cstring($keccak_256(value))

template keccak*(value: cstring): cstring =
  ($value).keccak

  