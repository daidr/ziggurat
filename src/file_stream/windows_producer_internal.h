#ifndef ZIGGURAT_WINDOWS_PRODUCER_INTERNAL_H
#define ZIGGURAT_WINDOWS_PRODUCER_INTERNAL_H
#include "windows_core.h"
/* Private mode-checked entry points into the one channel engine. Authority
 * refusals never change terminal state; only the chosen producer can fail it. */
int zws_producer_begin_kind(ZwsChannel *,unsigned,int *head,uint32_t *);
int zws_producer_write_kind(ZwsChannel *,unsigned,const void *,size_t,uint32_t *);
int zws_producer_finish_kind(ZwsChannel *,unsigned,uint32_t *);
int zws_producer_fail_kind(ZwsChannel *,unsigned,int,uint32_t);
void zws_channel_cancel(ZwsChannel *);
void zws_producer_cancel_unfinished(ZwsChannel *);
HANDLE zws_channel_cancel_event(ZwsChannel *);
#endif
