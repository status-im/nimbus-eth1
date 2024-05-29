* Check whether `HashKey` can be reduced to a simple 32 byte array (see
  *desc_identifiers.nim*)

* Remove the `RlpData` accounts payload type. It is not needed as a separate
  data type. An application must know the layout. So it can be subsumed
  under `RawData` (which could be renamed `PlainData`.)
