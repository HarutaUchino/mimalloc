#ifndef MI_EVENT_LOG_H
#define MI_EVENT_LOG_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MI_EVENT_TYPE_ALLOC 1
#define MI_EVENT_TYPE_FREE  2
#define MI_MAX_EVENTS       5000000
#ifndef MI_MEMSET_ALLOC
#define MI_MEMSET_ALLOC     1
#endif
#ifndef MI_MEMSET_FREE
#define MI_MEMSET_FREE      2
#endif

void mi_log_event(int event_type);
void mi_event_log_flush(void);
void mi_event_log_set_paths(const char* csv_path, const char* raw_path);
void mi_log_memset(int memset_kind, size_t bytes);

#ifdef __cplusplus
}
#endif

#endif /* MI_EVENT_LOG_H */
