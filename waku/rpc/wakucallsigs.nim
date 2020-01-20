proc waku_version(): string
proc waku_info(): WhisperInfo
proc waku_setMaxMessageSize(size: uint64): bool
proc waku_setMinPoW(pow: float): bool
proc waku_markTrustedPeer(enode: string): bool

proc waku_newKeyPair(): Identifier
proc waku_addPrivateKey(key: string): Identifier
proc waku_deleteKeyPair(id: Identifier): bool
proc waku_hasKeyPair(id: Identifier): bool
proc waku_getPublicKey(id: Identifier): PublicKey
proc waku_getPrivateKey(id: Identifier): PrivateKey

proc waku_newSymKey(): Identifier
proc waku_addSymKey(key: string): Identifier
proc waku_generateSymKeyFromPassword(password: string): Identifier
proc waku_hasSymKey(id: Identifier): bool
proc waku_getSymKey(id: Identifier): SymKey
proc waku_deleteSymKey(id: Identifier): bool

proc waku_newMessageFilter(options: WhisperFilterOptions): Identifier
proc waku_deleteMessageFilter(id: Identifier): bool
proc waku_getFilterMessages(id: Identifier): seq[WhisperFilterMessage]
proc waku_post(message: WhisperPostMessage): bool

proc wakusim_generateTraffic(amount: int): bool
proc wakusim_generateRandomTraffic(amount: int): bool
