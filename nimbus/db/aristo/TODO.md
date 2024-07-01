* Check whether `HashKey` can be reduced to a simple 32 byte array (see
  *desc_identifiers.nim*)

* Re-visit `delTree()`. Suggestion is deleting small trees on the memory later,
  otherwise only deleting the root vertex (so it becomes inaccessible) and
  remember the follow up vertices which can travel through the tx-layers
  to be picked up by the backend store.

* Consider changing fetch/merge/delete prototypes for account and storage. At
  the moment they all use `openArray[]` for strictly 32 byte arrays (which is
  only implicitely enforced at run time -- i.e. it would fail otherwise.)

* Mental note: For *proof-mode* with pre-allocated locked vertices and Merkle
  keys, verification of a patyion tree must be done by computing sub-tree keys
  at the relative roots and comparing them with the pre-allocated Merkle keys.

* Remove legacy state format import from `deblobifyTo()` after a while (last
  updated 28/06/24).
