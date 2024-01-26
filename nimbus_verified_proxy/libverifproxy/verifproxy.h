/**
 * nimbus_verified_proxy
 * Copyright (c) 2024 Status Research & Development GmbH
 * Licensed and distributed under either of
 *   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
 *   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
 * at your option. This file may not be copied, modified, or distributed except according to those terms.
 */

#ifndef __verifproxy__
#define __verifproxy__

typedef struct VerifProxyContext VerifProxyContext;
typedef void (*onHeaderCallback)(const char* s, int t);

void quit(void);

VerifProxyContext* startVerifProxy(const char* configJson, onHeaderCallback onHeader);
void stopVerifProxy(VerifProxyContext*);

#endif /* __verifproxy__ */
