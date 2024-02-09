# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import 
  ../../network/state/state_content

type JsonBlockInfo* = object
  number*: uint64
  block_hash*: string
  state_root*: string

type JsonAccount* = object
  nonce*: string
  balance*: string
  storage_hash*: string
  code_hash*: string

type JsonBlock* = object
  `block`*: JsonBlockInfo
  address*: string
  account*: JsonAccount
  storage_slot*: string
  storage_value*: string
  account_proof*: seq[string]
  storage_proof*: seq[string]
  bytecode*: string

type JsonAccountTrieNode* = object
  content_key*: string
  content_id*: string
  content_value_offer*: string
  content_value_retrieval*: string

type JsonContractStorageTtrieNode* = object
  content_key*: string
  content_id*: string
  content_value_offer*: string
  content_value_retrieval*: string

type JsonContractBytecode* = object
  content_key*: string
  content_id*: string
  content_value_offer*: string
  content_value_retrieval*: string

type JsonGossipKVPair* = object
  content_key*: string
  content_value*: string

type JsonRecursiveGossip* = seq[JsonGossipKVPair]
