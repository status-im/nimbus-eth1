* Check whether `HashKey` can be reduced to a simple 32 byte array (see
  *desc_identifiers.nim*)

* Re-visit `delTree()`. Suggestion is deleting small trees on the memory later,
  otherwise only deleting the root vertex (so it becomes inaccessible) and
  remember the follow up vertices which can travel through the tx-layers
  to be picked up by the backend store.

* Mental note: For *proof-mode* with pre-allocated locked vertices and Merkle
  keys, verification of a partial tree must be done by computing sub-tree keys
  at the relative roots and comparing them with the pre-allocated Merkle keys.
