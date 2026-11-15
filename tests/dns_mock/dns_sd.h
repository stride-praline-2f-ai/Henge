#ifndef HENGE_TEST_DNS_SD_H
#define HENGE_TEST_DNS_SD_H
#include <stdint.h>
#define DNSSD_API
typedef uint32_t DNSServiceFlags;
typedef int32_t DNSServiceErrorType;
typedef struct MockDNS *DNSServiceRef;
enum { kDNSServiceErr_NoError = 0, kDNSServiceErr_NoSuchName = -65538,
       kDNSServiceErr_NoSuchRecord = -65554, kDNSServiceFlagsMoreComing = 1,
       kDNSServiceFlagsAdd = 2, kDNSServiceFlagsReturnIntermediates = 0x1000 };
typedef void (*DNSServiceQueryRecordReply)(DNSServiceRef, DNSServiceFlags, uint32_t,
    DNSServiceErrorType, const char *, uint16_t, uint16_t, uint16_t, const void *, uint32_t, void *);
DNSServiceErrorType DNSServiceQueryRecord(DNSServiceRef *, DNSServiceFlags, uint32_t,
    const char *, uint16_t, uint16_t, DNSServiceQueryRecordReply, void *);
int DNSServiceRefSockFD(DNSServiceRef);
DNSServiceErrorType DNSServiceProcessResult(DNSServiceRef);
void DNSServiceRefDeallocate(DNSServiceRef);
#endif
