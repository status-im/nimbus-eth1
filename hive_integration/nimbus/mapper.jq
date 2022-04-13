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
    "coinbase"   : .coinbase,
    "difficulty" : .difficulty,
    "extraData"  : .extraData,
    "gasLimit"   : .gasLimit,
    "mixHash"    : .mixHash,
    "nonce"      : .nonce,
    "parentHash" : .parentHash,
    "timestamp"  : .timestamp,
    "alloc"      : .alloc,
    "baseFeePerGas": .baseFeePerGas
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
    "terminalTotalDifficulty": env.HIVE_TERMINAL_TOTAL_DIFFICULTY|to_int,
  }|remove_empty
}
