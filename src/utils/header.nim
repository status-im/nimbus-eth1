type
  Header* = ref object
  # TODO

proc generateHeaderFromParentHeader*(
    computeDifficultyFn: proc(parentHeader: Header, timestamp: int): int,
    parentHeader: Header,
    coinbase: cstring,
    timestamp: int = -1,
    extraData: cstring = cstring""): Header =
  Header()
  # Generate BlockHeader from state_root and parent_header
  # if timestamp is None:
  #       timestamp = max(int(time.time()), parent_header.timestamp + 1)
  #   elif timestamp <= parent_header.timestamp:
  #       raise ValueError(
  #           "header.timestamp ({}) should be higher than"
  #           "parent_header.timestamp ({})".format(
  #               timestamp,
  #               parent_header.timestamp,
  #           )
  #       )
  #   header = BlockHeader(
  #       difficulty=compute_difficulty_fn(parent_header, timestamp),
  #       block_number=(parent_header.block_number + 1),
  #       gas_limit=compute_gas_limit(
  #           parent_header,
  #           gas_limit_floor=GENESIS_GAS_LIMIT,
  #       ),
  #       timestamp=timestamp,
  #       parent_hash=parent_header.hash,
  #       state_root=parent_header.state_root,
  #       coinbase=coinbase,
  #       extra_data=extra_data,
  #   )

  #   return header
