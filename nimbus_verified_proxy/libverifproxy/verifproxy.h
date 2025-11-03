/**
 * nimbus_verified_proxy
<<<<<<< HEAD
 * Copyright (c) 2024-2025 Status Research & Development GmbH
=======
 * Copyright (c) 2025 Status Research & Development GmbH
>>>>>>> 68847053f (init)
 * Licensed and distributed under either of
 *   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
 *   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
 * at your option. This file may not be copied, modified, or distributed except according to those terms.
 */

#ifndef __verifproxy__
#define __verifproxy__

#ifdef __cplusplus
extern "C" {
#endif

#ifndef __has_attribute
#define __has_attribute(x) 0
#endif

#ifndef __has_feature
#define __has_feature(x) 0
#endif

#if __has_attribute(warn_unused_result)
#define ETH_RESULT_USE_CHECK __attribute__((warn_unused_result))
#else
#define ETH_RESULT_USE_CHECK
#endif

void NimMain(void);

typedef struct Context Context;

ETH_RESULT_USE_CHECK Context *createAsyncTaskContext();

typedef void (*CallBackProc) (Context *ctx, int status, char *res);

void eth_blockNumber(Context *ctx, CallBackProc cb);
void freeResponse(char *res);
void freeContext(Context *ctx);
void nonBusySleep(Context *ctx, int secs, CallBackProc cb);
void startVerifProxy(Context *ctx, char* configJson, CallBackProc onstart);
void stopVerifProxy(Context *ctx);
void pollAsyncTaskEngine(Context *ctx);

#ifdef __cplusplus
}
#endif

#endif /* __verifproxy__ */
