import results

export results

const
  # https://github.com/facebook/rocksdb/wiki/Setup-Options-and-Basic-Tuning
  defaultMaxOpenFiles* = 512
  defaultWriteBufferSize* = 64 * 1024 * 1024
  defaultRowCacheSize* = 512 * 1024 * 1024
  defaultBlockCacheSize* = 256 * 1024 * 1024

type
  DbOptions* = object
    # Options that are transported to the database layer
    maxOpenFiles*: int
    writeBufferSize*: int
    rowCacheSize*: int
    blockCacheSize*: int

func init*(
    T: type DbOptions,
    maxOpenFiles = defaultMaxOpenFiles,
    writeBufferSize = defaultWriteBufferSize,
    rowCacheSize = defaultRowCacheSize,
    blockCacheSize = defaultBlockCacheSize,
): T =
  T(
    maxOpenFiles: maxOpenFiles,
    writeBufferSize: writeBufferSize,
    rowCacheSize: rowCacheSize,
    blockCacheSize: blockCacheSize,
  )
