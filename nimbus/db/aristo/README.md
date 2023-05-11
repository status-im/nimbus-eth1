Aristo Trie -- a Patricia Trie with Merkle hash labeled edges
=============================================================
These data structures allows to overlay the *Patricia Trie* with *Merkel
Trie* hashes. With a particular layout, the structure is called
and *Aristo Trie* (Patricia = Roman Aristocrat, Patrician.)

This description does assume familiarity with the abstract notion of a hexary
*Merkle Patricia [Trie](https://en.wikipedia.org/wiki/Trie)*. Suffice it to
say the state of a valid *Merkle Patricia Tree* is uniquely verified by its
top level vertex.

1. Deleting entries in a compact *Merkle Patricia Tree*
-------------------------------------------------------
The main feature of the *Aristo Trie* representation is that there are no
double used nodes any sub-trie as it happens with the representation as a
[compact Merkle Patricia Tree](http://archive.is/TinyK). For example,
consider the following state data for the latter.

      leaf = (0xf,0x12345678)                                            (1)
      branch = (a,a,a,,, ..) with a = hash(leaf)
      root = hash(branch)

These two nodes, called *leaf* and *branch*, and the *root* hash are a state
(aka key-value pairs) representation as a *compact Merkle Patricia Tree*. The
actual state is

      0x0f ==> 0x12345678
      0x1f ==> 0x12345678
      0x2f ==> 0x12345678

The elements from *(1)* can be organised in a key-value table with the *Merkle*
hashes as lookup keys

      a    -> leaf
      root -> branch

This is a space efficient way of keeping data as there is no duplication of
the sub-trees made up by the *Leaf* node with the same payload *0x12345678*
and path snippet *0xf*. One can imagine how this property applies to more
general sub-trees in a similar fashion.

Now delete some key-value pair of the state, e.g. for the key *0x0f*. This
amounts to removing the first of the three *a* hashes from the *branch*
record. The new state of the *Merkle Patricia Tree* will look like

      leaf = (0xf,0x12345678)                                            (2)
      branch1 = (,a,a,,, ..)
      root1 = hash(branch1)

      a     -> leaf
      root1 -> branch1

A problem arises when all keys are deleted and there is no reference to the
*leaf* data record, anymore. One should find out in general when it can be
deleted, too. It might be unknown whether the previous states leading to here
had only a single *Branch* record referencing to this *leaf* data record.

Finding a stale data record can be achieved by a *mark and sweep* algorithm,
but it becomes too clumsy to be useful on a large state (i.e. database).
Reference counts come to mind but maintaining these is generally error prone
when actors concurrently manipulate the state (i.e. database).

2. *Patricia Trie* example with *Merkle hash* labelled edges
------------------------------------------------------------
Continuing with the example from chapter 1, the *branch* node is extended by
an additional set of structural identifiers *x, w, z*. It allows to handle
the deletion of entries in a more benign way while keeping the *Merkle hashes*
for validating sub-trees.

A solution for the deletion problem is to represent the situation *(1)* as

      leaf-a = (0xf,0x12345678) copy of leaf from (1)                    (3)
      leaf-b = (0xf,0x12345678) copy of leaf from (1)
      leaf-c = (0xf,0x12345678) copy of leaf from (1)
      branch2 = ((x,y,z,,, ..)(a,b,c,,, ..))
      root2 = (w,root) with root from (1)

where

      a = hash(leaf-a) same as a from (1)
      b = hash(leaf-b) same as a from (1)
      c = hash(leaf-c) same as a from (1)

      w,x,y,z numbers, mutually different

The records above are stored in a key-value database as

      w -> branch2
      x -> leaf-a
      y -> leaf-b
      z -> leaf-c

Then this structure encodes the key-value pairs as before

      0x0f ==> 0x12345678
      0x1f ==> 0x12345678
      0x2f ==> 0x12345678

Deleting the data for key *0x0f* now results in the new state

      leaf-b = (0xf,0x12345678)                                          (4)
      leaf-c = (0xf,0x12345678)
      branch3 = ((,y,z,,, ..)(,b,c,,, ..))

      w -> branch3
      y -> leaf-b
      z -> leaf-c

Due to duplication of the *leaf* node in *(3)*, no reference count is needed
in order to detect stale records cleanly when deleting key *0x0f*. Removing
this key allows to remove hash *a* from *branch2* as well as also structural
key *x* which will consequently be deleted from the lookup table.

A minor observation is that manipulating a state entry, e.g. changing the
payload associated with key *0x0f* to

      0x0f ==> 0x987654321

the structural layout of the above trie will not change, that is the indexes
*w, x, y, z* of the table that holds the data records as values. All that
changes are values.

      leaf-d = (0xf,0x987654321)                                         (5)
      leaf-b = (0xf,0x12345678)
      leaf-c = (0xf,0x12345678)
      branch3 = ((x,y,z,,, ..)(d,b,c,,, ..))

      root3 = (w,hash(d,b,c,,, ..))

3. Discussion of the examples *(1)* and *(3)*
---------------------------------------------
Examples *(1)* and *(3)* differ in that the structural *Patricia Trie*
information from *(1)* has been removed from the *Merkle hash* instances and
implemented as separate table lookup IDs (called *vertexID*s later on.) The
values of these lookup IDs are arbitrary as long as they are all different.

In fact, the [Erigon](http://archive.is/6MJV7) project discusses a similar
situation in **Separation of keys and the structure**, albeit aiming for a
another scenario with the goal of using mostly flat data lookup structures.

A graph for the example *(1)* would look like

                |
               root
                |
         +-------------+
         |   branch    |
         +-------------+
              | | |
              a a a
              | | |
              leaf

while example *(2)* has

              (root)                                                     (6)
                |
                w
                |
         +-------------+
         |   branch2   |
         | (a) (b) (c) |
         +-------------+
            /   |   \
           x    y    z
          /     |     \
       leaf-a leaf-b leaf-c

The labels on the edges indicate the downward target of an edge while the
round brackets enclose separated *Merkle hash* information.

This last example (6) can be completely split into structural tree and Merkel
hash mapping.

         structural trie              hash map                           (7)
         ---------------              --------
                |                  (root) -> w
                w                     (a) -> x
                |                     (b) -> y
         +-------------+              (c) -> z
         |   branch2   |
         +-------------+
            /   |   \
           x    y    z
          /     |     \
       leaf-a leaf-b leaf-c


4. *Patricia Trie* node serialisation with *Merkle hash* labelled edges
-----------------------------------------------------------------------
The data structure for the *Aristo Trie* forllows example *(7)* by keeping
structural information separate from the Merkle hash labels. As for teminology,

* an *Aristo Trie* is a pair *(structural trie, hash map)* where
* the *structural trie* realises a haxary *Patricia Trie* containing the payload
  values in the leaf records
* the *hash map* contains the hash information so that this trie operates as a
  *Merkle Patricia Tree*.

In order to accommodate for the additional structural elements, a non RLP-based
data layout is used for the *Branch*, *Extension*, and *Leaf* containers used
in the key-value table that implements the *Patricia Trie*. It is now called
*Aristo Trie* for this particular data layout.

The structural keys *w, x, y, z* from the example *(3)* are called *vertexID*
and implemented as 64 bit values, stored *Big Endian* in the serialisation.

### Branch record serialisation

        0 +--+--+--+--+--+--+--+--+--+
          |                          |       -- first vertexID
        8 +--+--+--+--+--+--+--+--+--+
          ...                                -- more vertexIDs
          +--+--+
          |     |                            -- access(16) bitmap
          +--+--+
          || |                               -- marker(2) + unused(6)
          +--+

        where
          marker(2) is the double bit array 00

For a given index *n* between *0..15*, if the bit at position *n* of the it
vector *access(16)* is reset to zero, then there is no *n*-th structural
*vertexID*. Otherwise one calculates

        the n-th vertexID is at position Vn * 8
        for Vn the number of non-zero bits in the range 0..(n-1) of access(16)

Note that data are stored *Big Endian*, so the bits *0..7* of *access* are
stored in the right byte of the serialised bitmap.

### Extension record serialisation

        0 +--+--+--+--+--+--+--+--+--+
          |                          |       -- vertexID
        8 +--+--+--+--+--+--+--+--+--+
          |  | ...                           -- path segment
          +--+
          || |                               -- marker(2) + pathSegmentLen(6)
          +--+

        where
          marker(2) is the double bit array 10

The path segment of the *Extension* record is compact encoded. So it has at
least one byte. The first byte *P0* has bit 5 reset, i.e. *P0 and 0x20* is
zero (bit 4 is set if the right nibble is the first part of the path.)

Note that the *pathSegmentLen(6)* is redunant as it is determined by the length
of the extension record (as *recordLen - 9*.)

### Leaf record serialisation

        0 +-- ..
          ...                                -- payload (may be empty)
          +--+
          |  | ...                           -- path segment
          +--+
          || |                               -- marker(2) + pathSegmentLen(6)
          +--+

        where
          marker(2) is the double bit array 11

A *Leaf* record path segment is compact encoded. So it has at least one byte.
The first byte *P0* has bit 5 set, i.e. *P0 and 0x20* is non-zero (bit 4 is
also set if the right nibble is the first part of the path.)

### Descriptor record serialisation

        0 +-- ..
          ...                                -- recycled vertexIDs
          +--+--+--+--+--+--+--+--+--+
          |                          |       -- bottom of unused vertexIDs
          +--+--+--+--+--+--+--+--+--+
          || |                               -- marker(2) + unused(6)
          +--+

        where
          marker(2) is the double bit array 01

Currently, the descriptor record only contains data for producing unique
vectorID values that can be used as structural keys. If this descriptor is
missing, the value `(0x40000000,0x01)` is assumed. The last vertexID in the
descriptor list has the property that that all values greater or equal than
this value can be used as vertexID.

The vertexIDs in the descriptor record must all be non-zero and record itself
should be allocated in the structural table associated with the zero key.
