#ifndef __verifproxy__
#define __verifproxy__

typedef struct VerifProxyContext VerifProxyContext;
typedef void (*onHeaderCallback)(const char* s, int t);

void quit(void);
VerifProxyContext* startVerifProxy(const char* configJson, onHeaderCallback onHeader);
void stopVerifProxy(VerifProxyContext*);

#endif /* __verifproxy__ */
