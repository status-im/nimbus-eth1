# nimbus_history_exporter

Tool for exporting and verifying Ethereum history data in [ere](https://github.com/eth-clients/e2store-format-specs/blob/ca2523a6420d64336000f5607c0b59df1a08c83b/formats/ere.md) and [era1](https://github.com/eth-clients/e2store-format-specs/blob/master/formats/era1.md) formats.

`ere` files hold one era (8192 blocks) of data: headers, bodies, receipts, proofs, and total difficulty. They cover the full Ethereum history: the pre-merge, merge, and post-merge eras.

## Commands

| Command | Description |
|---|---|
| `exportEre` | Export ere files from the Nimbus EL database (primary method) |
| `verifyEre` | Verify all ere files in a directory |
| `verifyEreFile` | Verify a single ere file |
| `exportEreFromEra1` | Export ere files from era1 archive files (pre-merge only) |
| `exportEra1` | Export era1 files from the Nimbus EL database |
| `verifyEra1` | Verify all era1 files in a directory |
| `exportAccumulator` | Export the pre-merge HistoricalHashesAccumulator SSZ file |
| `printAccumulator` | Print the contents of an accumulator SSZ file |


## Prerequisite: Importing with body and receipt storage

The `exportEre` and `exportEra1` commands read block bodies and receipts from the Nimbus execution client's database. These are **not stored by default** during block import; you must pass two hidden flags to the `import` command:

```sh
nimbus_execution_client import \
  --era1-dir:/path/to/era1 \
  --era-dir:/path/to/era \
  --debug-store-bodies \
  --debug-store-receipts
```

Without `--debug-store-bodies` and `--debug-store-receipts`, the database will be missing the data that the exporter needs.

> **Note:** These flags are currently marked hidden/debug and subject to change once the UX stabilises.


## ere export from the EL data directory (primary method)

`exportEre` reads block data directly from the Nimbus execution client's data directory to produce `ere` files.

Export all available eras (default behaviour):

```sh
nimbus_history_exporter exportEre \
  --el-data-dir:/path/to/nimbus/mainnet \
  --era-dir:/path/to/nimbus/mainnet/era
```

Export a specific range:

```sh
nimbus_history_exporter exportEre \
  --el-data-dir:/path/to/nimbus/mainnet \
  --era-dir:/path/to/nimbus/mainnet/era \
  --era:100 \
  --era-count:500
```

`ere` files are written to `<el-data-dir>/ere/` by default.

`--era-dir` is only required for post-merge eras (at or beyond the merge block), where beacon chain era files are needed to build block proofs. For pre-merge eras, proofs are built from epoch records derived from the EL database headers; the `HistoricalHashesAccumulator` embedded in the binary is used during verification of those proofs.


## ere verification

### Verify a directory of ere files

Loads all `.ere` files in the given directory and verifies each one. The `HistoricalHashesAccumulator` (for pre-merge proofs) is embedded in the binary. Historical roots and historical summaries (for post-merge proofs) are loaded from the beacon chain era files.

```sh
nimbus_history_exporter verifyEre \
  --ere-dir:/path/to/ere \
  --era-dir:/path/to/nimbus/mainnet/era
```

### Verify a single ere file

```sh
nimbus_history_exporter verifyEreFile \
  --ere-file:/path/to/sepolia-00500-e0c67138.ere \
  --era-dir:/path/to/nimbus/sepolia/era
```

## ere export from era1 files (alternative pre-merge method)

If the EL database is not available, pre-merge `ere` files can be produced from `era1` archive files instead. This path only covers eras before the merge and any requested range beyond the merge era is capped.

```sh
nimbus_history_exporter exportEreFromEra1 \
  --era1-dir:/path/to/era1
```

`ere` files are written to `<era1-dir>/../ere/` by default, or to `--ere-dir` if specified.


## era1 export and verification

`era1` files cover pre-merge history only and are exported from the Nimbus EL database.

### Export

```sh
nimbus_history_exporter exportEra1 \
  --el-data-dir:/path/to/nimbus/mainnet \
  --era1-dir:/path/to/output/era1
```

### Verify

```sh
nimbus_history_exporter verifyEra1 \
  --era1-dir:/path/to/era1
```
