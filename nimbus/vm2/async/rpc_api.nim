import
  chronicles,
  chronos,
  json,
  options,
  sequtils,
  stint,
  strutils,
  times,
  typetraits,
  stew/byteutils,
  json_rpc/rpcclient,
  eth/common/eth_types,
  ../../tests/rpcclient/eth_api  # FIXME-Adam: I know I'm not supposed to use this one, but nim-web3 has been giving me errors

# FIXME-Adam: just trying to be clear about which imports come from where.
# In the long run, get nim-web3 to work properly and then clean this up.
from ../../rpc/rpc_utils import toHash
from web3 import Web3, BlockObject, FixedBytes, newWeb3, fromJson, fromHex
from ../../premix/downloader import request
from ../../premix/parser import prefixHex, parseBlockHeader, parseReceipt, parseTransaction

# Trying to do things the new web3 way:
# from web3 import eth_getProof, Address, StorageProof, blockId, `%`
# from ../../lc_proxy/validate_proof import getAccountFromProof


var durationSpentDoingFetches*: times.Duration
var fetchCounter*: int


func toHash*(s: string): Hash256 {.raises: [Defect, ValueError].} =
  hexToPaddedByteArray[32](s).toHash


proc makeAnRpcClient*(web3Url: string): Future[RpcClient] {.async.} =
  let myWeb3: Web3 = waitFor(newWeb3(web3Url))
  return myWeb3.provider


proc fetchBlockHeaderWithHash*(rpcClient: RpcClient, h: Hash256): Future[BlockHeader] {.async.} =
  let t0 = now()
  let r = request("eth_getBlockByHash", %[%h.prefixHex, %false], some(rpcClient))
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  if r.kind == JNull:
    error "requested block not available", blockHash=h
    raise newException(ValueError, "Error when retrieving block header")
  return parseBlockHeader(r)

proc fetchBlockHeaderWithNumber*(rpcClient: RpcClient, n: BlockNumber): Future[BlockHeader] {.async.} =
  let t0 = now()
  let r = request("eth_getBlockByNumber", %[%n.prefixHex, %false], some(rpcClient))
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  if r.kind == JNull:
    error "requested block not available", blockNumber=n
    raise newException(ValueError, "Error when retrieving block header")
  return parseBlockHeader(r)

proc fetchBlockHeaderAndBodyWithHash*(rpcClient: RpcClient, h: Hash256): Future[(BlockHeader, BlockBody)] {.async.} =
  let t0 = now()
  let r = request("eth_getBlockByHash", %[%h.prefixHex, %true], some(rpcClient))
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  if r.kind == JNull:
    error "requested block not available", blockHash=h
    raise newException(ValueError, "Error when retrieving block header and body")
  let header = parseBlockHeader(r)
  var body: BlockBody
  for tn in r["transactions"].getElems:
    body.transactions.add(parseTransaction(tn))
  for un in r["uncles"].getElems:
    let uncleHash: Hash256 = un.getStr.toHash
    let uncleHeader = await fetchBlockHeaderWithHash(rpcClient, uncleHash)
    body.uncles.add(uncleHeader)
  return (header, body)

func mdigestFromFixedBytes*(arg: FixedBytes[32]): MDigest[256] =
  MDigest[256](data: distinctBase(arg))

func mdigestFromString*(s: string): MDigest[256] =
  mdigestFromFixedBytes(FixedBytes[32].fromHex(s))

type
  AccountProof* = seq[seq[byte]]

proc fetchAccountAndSlots*(rpcClient: RpcClient, address: EthAddress, slots: seq[UInt256], blockNumber: BlockNumber): Future[(Account, AccountProof, seq[StorageProof])] {.async.} =
  let t0 = now()
  debug "Got to fetchAccountAndSlots", address=address, slots=slots, blockNumber=blockNumber
  let addressStr: EthAddressStr = ethAddressStr(address)
  let slotHexStrs: seq[HexDataStr] = slots.mapIt(HexDataStr(string(encodeQuantity(it))))
  let blockNumberHexStr: HexQuantityStr = encodeQuantity(blockNumber)
  debug "About to call eth_getProof", address=string(addressStr), slots=slots, blockNumber=string(blockNumberHexStr)
  let proofResponse: ProofResponse = await rpcClient.eth_getProof(addressStr, slotHexStrs, string(blockNumberHexStr))
  debug "Received response to eth_getProof", proofResponse=proofResponse
  let acc = Account(
    nonce: uint64(parseHexInt(string(proofResponse.nonce))),
    balance: UInt256.fromHex(string(proofResponse.balance)),
    storageRoot: mdigestFromString(string(proofResponse.storageHash)),
    codeHash: mdigestFromString(string(proofResponse.codeHash))
  )
  debug "Parsed response to eth_getProof", acc=acc
  let accProof: seq[seq[byte]] = proofResponse.accountProof.mapIt(hexToSeqByte(string(it)))
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  return (acc, accProof, proofResponse.storageProof)

#[
FIXME-Adam: Here's my attempt to use the nim-web3 stuff, but I had trouble.

proc fetchAccountAndSlots*(rpcClient: RpcClient, address: EthAddress, slots: seq[UInt256], blockNumber: BlockNumber): Future[(Account, AccountProof, seq[StorageProof])] {.async.} =
  debug "About to call eth_getProof", address=address, slots=slots, blockNumber=blockNumber

  let a = Address(address)
  let bid = blockId(blockNumber.truncate(uint64))


  let json = %[a, slots, bid]
  debug "here's the JSON", json=json
  let proof = await rpcClient.eth_getProof(a, slots, bid)
  

  
  debug "Received response to eth_getProof", proof=proof
  let acc = Account(
    nonce: distinctBase(proof.nonce),
    balance: proof.balance,
    storageRoot: mdigestFromFixedBytes(proof.storageHash),
    codeHash: mdigestFromFixedBytes(proof.codeHash)
  )
  debug "Parsed response to eth_getProof", acc=acc
  let mptNodesBytes: seq[seq[byte]] = proof.accountProof.mapIt(distinctBase(it))
  return (acc, mptNodesBytes, proof.storageProof)
]#

proc fetchCode*(client: RpcClient, blockNumber: BlockNumber, address: EthAddress): Future[seq[byte]] {.async.} =
  let t0 = now()
  let blockNumberHexStr: HexQuantityStr = encodeQuantity(blockNumber)
  let fetchedCodeHexStr: HexDataStr = await client.eth_getCode(ethAddressStr(address), string(blockNumberHexStr))
  let fetchedCode: seq[byte] = hexToSeqByte(string(fetchedCodeHexStr))
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  return fetchedCode

proc parseQuantity(s: string): uint64 =
  uint64(parseHexInt(s.substr(2)))

proc fetchTxReceipt*(rpcClient: RpcClient, txHash: Hash256): Future[Receipt] {.async.} =
  let r = request("eth_getTransactionReceipt", %[%txHash.prefixHex], some(rpcClient))
  if r.kind == JNull:
    error "requested tx receipt not available", txHash=txHash
    raise newException(ValueError, "Error when retrieving tx receipt")
  let gasUsed = parseQuantity(getStr(r["gasUsed"]))
  let cumulativeGasUsed = parseQuantity(getStr(r["cumulativeGasUsed"]))
  let receipt = parseReceipt(r)
  return receipt
