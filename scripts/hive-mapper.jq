# This script is a copy of the script located at:
# https://github.com/ethereum/hive/blob/master/clients/nimbus-el/mapper.jq
# It is used in the hive-run-nimbus.sh script.

def walk(f):
  . as $in
  | if type == "object" then
      reduce keys_unsorted[] as $key
        ( {}; . + { ($key):  ($in[$key] | walk(f)) } ) | f
  elif type == "array" then map( walk(f) ) | f
  else f
  end;

# Removes all empty keys and values in input.
def remove_empty:
  . | walk(
    if type == "object" then
      with_entries(
        select(
          .value != null and
          .value != "" and
          .value != [] and
          .key != null and
          .key != ""
        )
      )
    else .
    end
  )
;

# Converts decimal string to number.
def to_int:
  if . == null then . else .|tonumber end
;

# Converts "1" / "0" to boolean.
def to_bool:
  if . == null then . else
    if . == "1" then true else false end
  end
;

# Replace config in input.
{
  "genesis": {
    "coinbase"     : .coinbase,
    "difficulty"   : .difficulty,
    "extraData"    : .extraData,
    "gasLimit"     : .gasLimit,
    "mixHash"      : .mixHash,
    "nonce"        : .nonce,
    "parentHash"   : .parentHash,
    "timestamp"    : .timestamp,
    "alloc"        : .alloc,
    "baseFeePerGas": .baseFeePerGas,
    "excessBlobGas": .excessBlobGas,
    "blobGasUsed"  : .blobGasUsed
  }|remove_empty,
  "config": {
    "clique": (if env.HIVE_CLIQUE_PERIOD == null then null else {
      "period": env.HIVE_CLIQUE_PERIOD|to_int,
    } end),
    "chainId": env.HIVE_CHAIN_ID|to_int,
    "homesteadBlock": env.HIVE_FORK_HOMESTEAD|to_int,
    "daoForkBlock": env.HIVE_FORK_DAO_BLOCK|to_int,
    "daoForkSupport": (if env.HIVE_FORK_DAO_BLOCK then env.HIVE_FORK_DAO_VOTE|to_bool else null end),
    "eip150Block": env.HIVE_FORK_TANGERINE|to_int,
    "eip155Block": env.HIVE_FORK_SPURIOUS|to_int,
    "eip158Block": env.HIVE_FORK_SPURIOUS|to_int,
    "byzantiumBlock": env.HIVE_FORK_BYZANTIUM|to_int,
    "constantinopleBlock": env.HIVE_FORK_CONSTANTINOPLE|to_int,
    "petersburgBlock": env.HIVE_FORK_PETERSBURG|to_int,
    "istanbulBlock": env.HIVE_FORK_ISTANBUL|to_int,
    "muirGlacierBlock": env.HIVE_FORK_MUIR_GLACIER|to_int,
    "berlinBlock": env.HIVE_FORK_BERLIN|to_int,
    "londonBlock": env.HIVE_FORK_LONDON|to_int,
    "arrowGlacierBlock": env.HIVE_FORK_ARROW_GLACIER|to_int,
    "grayGlacierBlock": env.HIVE_FORK_GRAY_GLACIER|to_int,
    "mergeNetsplitBlock": env.HIVE_MERGE_BLOCK_ID|to_int,
    "terminalTotalDifficulty": env.HIVE_TERMINAL_TOTAL_DIFFICULTY|to_int,
    "shanghaiTime": env.HIVE_SHANGHAI_TIMESTAMP|to_int,
    "cancunTime": env.HIVE_CANCUN_TIMESTAMP|to_int,
    "pragueTime": env.HIVE_PRAGUE_TIMESTAMP|to_int,
    "osakaTime": env.HIVE_OSAKA_TIMESTAMP|to_int,
    "amsterdamTime": env.HIVE_AMSTERDAM_TIMESTAMP|to_int,
    "blobSchedule": {
      "cancun": {
        "target": (if env.HIVE_CANCUN_BLOB_TARGET then env.HIVE_CANCUN_BLOB_TARGET|to_int else 3 end),
        "max": (if env.HIVE_CANCUN_BLOB_MAX then env.HIVE_CANCUN_BLOB_MAX|to_int else 6 end),
        "baseFeeUpdateFraction": (if env.HIVE_CANCUN_BLOB_BASE_FEE_UPDATE_FRACTION then env.HIVE_CANCUN_BLOB_BASE_FEE_UPDATE_FRACTION|to_int else 3338477 end)
      },
      "prague": {
        "target": (if env.HIVE_PRAGUE_BLOB_TARGET then env.HIVE_PRAGUE_BLOB_TARGET|to_int else 6 end),
        "max": (if env.HIVE_PRAGUE_BLOB_MAX then env.HIVE_PRAGUE_BLOB_MAX|to_int else 9 end),
        "baseFeeUpdateFraction": (if env.HIVE_PRAGUE_BLOB_BASE_FEE_UPDATE_FRACTION then env.HIVE_PRAGUE_BLOB_BASE_FEE_UPDATE_FRACTION|to_int else 5007716 end)
      },
      "osaka": {
        "target": (if env.HIVE_OSAKA_BLOB_TARGET then env.HIVE_OSAKA_BLOB_TARGET|to_int else 6 end),
        "max": (if env.HIVE_OSAKA_BLOB_MAX then env.HIVE_OSAKA_BLOB_MAX|to_int else 9 end),
        "baseFeeUpdateFraction": (if env.HIVE_OSAKA_BLOB_BASE_FEE_UPDATE_FRACTION then env.HIVE_OSAKA_BLOB_BASE_FEE_UPDATE_FRACTION|to_int else 5007716 end)
      },
      "amsterdam": {
        "target": (if env.HIVE_AMSTERDAM_BLOB_TARGET then env.HIVE_AMSTERDAM_BLOB_TARGET|to_int else 6 end),
        "max": (if env.HIVE_AMSTERDAM_BLOB_MAX then env.HIVE_AMSTERDAM_BLOB_MAX|to_int else 9 end),
        "baseFeeUpdateFraction": (if env.HIVE_AMSTERDAM_BLOB_BASE_FEE_UPDATE_FRACTION then env.HIVE_AMSTERDAM_BLOB_BASE_FEE_UPDATE_FRACTION|to_int else 5007716 end)
      },
      "bpo1": {
        "target": (if env.HIVE_BPO1_BLOB_TARGET then env.HIVE_BPO1_BLOB_TARGET|to_int else 10 end),
        "max": (if env.HIVE_BPO1_BLOB_MAX then env.HIVE_BPO1_BLOB_MAX|to_int else 15 end),
        "baseFeeUpdateFraction": (if env.HIVE_BPO1_BLOB_BASE_FEE_UPDATE_FRACTION then env.HIVE_BPO1_BLOB_BASE_FEE_UPDATE_FRACTION|to_int else 8346193 end)
      },
      "bpo2": {
        "target": (if env.HIVE_BPO2_BLOB_TARGET then env.HIVE_BPO2_BLOB_TARGET|to_int else 14 end),
        "max": (if env.HIVE_BPO2_BLOB_MAX then env.HIVE_BPO2_BLOB_MAX|to_int else 21 end),
        "baseFeeUpdateFraction": (if env.HIVE_BPO2_BLOB_BASE_FEE_UPDATE_FRACTION then env.HIVE_BPO2_BLOB_BASE_FEE_UPDATE_FRACTION|to_int else 11684671 end)
      },
      "bpo3": {
        "target": (if env.HIVE_BPO3_BLOB_TARGET then env.HIVE_BPO3_BLOB_TARGET|to_int else 9 end),
        "max": (if env.HIVE_BPO3_BLOB_MAX then env.HIVE_BPO3_BLOB_MAX|to_int else 14 end),
        "baseFeeUpdateFraction": (if env.HIVE_BPO3_BLOB_BASE_FEE_UPDATE_FRACTION then env.HIVE_BPO3_BLOB_BASE_FEE_UPDATE_FRACTION|to_int else 8832827 end)
      },
      "bpo4": {
        "target": (if env.HIVE_BPO4_BLOB_TARGET then env.HIVE_BPO4_BLOB_TARGET|to_int else 9 end),
        "max": (if env.HIVE_BPO4_BLOB_MAX then env.HIVE_BPO4_BLOB_MAX|to_int else 14 end),
        "baseFeeUpdateFraction": (if env.HIVE_BPO4_BLOB_BASE_FEE_UPDATE_FRACTION then env.HIVE_BPO4_BLOB_BASE_FEE_UPDATE_FRACTION|to_int else 8832827 end)
      },
      "bpo5": {
        "target": (if env.HIVE_BPO5_BLOB_TARGET then env.HIVE_BPO5_BLOB_TARGET|to_int else 9 end),
        "max": (if env.HIVE_BPO5_BLOB_MAX then env.HIVE_BPO5_BLOB_MAX|to_int else 14 end),
        "baseFeeUpdateFraction": (if env.HIVE_BPO5_BLOB_BASE_FEE_UPDATE_FRACTION then env.HIVE_BPO5_BLOB_BASE_FEE_UPDATE_FRACTION|to_int else 8832827 end)
      }
    },
    "bpo1Time": env.HIVE_BPO1_TIMESTAMP|to_int,
    "bpo2Time": env.HIVE_BPO2_TIMESTAMP|to_int,
    "bpo3Time": env.HIVE_BPO3_TIMESTAMP|to_int,
    "bpo4Time": env.HIVE_BPO4_TIMESTAMP|to_int,
    "bpo5Time": env.HIVE_BPO5_TIMESTAMP|to_int,
    "depositContractAddress": "0x00000000219ab540356cBB839Cbe05303d7705Fa",
  }|remove_empty
}
