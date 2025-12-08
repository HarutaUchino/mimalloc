#include "mi_event_log.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct mi_event {
  uint64_t timestamp_us;
  uint8_t  event_type;
  uint64_t alloc_count;
  uint64_t free_count;
  int64_t  delta;
};

static struct mi_event        events[MI_MAX_EVENTS];
static _Atomic uint64_t       event_index = 0;
static _Atomic uint64_t       mi_alloc_calls = 0;
static _Atomic uint64_t       mi_free_calls = 0;
static _Atomic int            mi_log_state = 0; /* 0 = not started, 1 = initializing, 2 = ready */
static _Atomic int            mi_flush_registered = 0;
static uint64_t               mi_start_us = 0;
static const char*            mi_log_csv_path = "/tmp/mimalloc-events.csv";
static const char*            mi_log_raw_path = NULL;

static uint64_t mi_now_us(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
    return 0;
  }
  return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)(ts.tv_nsec / 1000ULL);
}

static void mi_event_log_register_flush(void) {
  int expected = 0;
  if (atomic_compare_exchange_strong(&mi_flush_registered, &expected, 1)) {
    atexit(mi_event_log_flush);
  }
}

static void mi_event_log_init(void) {
  int expected = 0;
  if (atomic_compare_exchange_strong(&mi_log_state, &expected, 1)) {
    const char* csv_env = getenv("MI_LOG_CSV");
    if (csv_env != NULL && csv_env[0] != '\0') {
      mi_log_csv_path = csv_env;
    }
    const char* raw_env = getenv("MI_LOG_RAW");
    if (raw_env != NULL && raw_env[0] != '\0') {
      mi_log_raw_path = raw_env;
    }
    mi_start_us = mi_now_us();
    mi_event_log_register_flush();
    atomic_store(&mi_log_state, 2);
  }
  else {
    while (atomic_load(&mi_log_state) == 1) {
      ; /* wait for initialization */
    }
  }
}

static uint64_t mi_record_index(void) {
  uint64_t index = atomic_fetch_add_explicit(&event_index, 1, memory_order_relaxed);
  if (index >= MI_MAX_EVENTS) {
    return MI_MAX_EVENTS;
  }
  return index;
}

void mi_log_event(int event_type) {
  if (event_type != MI_EVENT_TYPE_ALLOC && event_type != MI_EVENT_TYPE_FREE) {
    return;
  }
  mi_event_log_init();
  const uint64_t slot = mi_record_index();
  if (slot >= MI_MAX_EVENTS) {
    return; /* buffer full */
  }

  uint64_t alloc_total;
  uint64_t free_total;
  if (event_type == MI_EVENT_TYPE_ALLOC) {
    alloc_total = atomic_fetch_add_explicit(&mi_alloc_calls, 1, memory_order_relaxed) + 1;
    free_total = atomic_load_explicit(&mi_free_calls, memory_order_relaxed);
  }
  else {
    free_total = atomic_fetch_add_explicit(&mi_free_calls, 1, memory_order_relaxed) + 1;
    alloc_total = atomic_load_explicit(&mi_alloc_calls, memory_order_relaxed);
  }

  struct mi_event evt;
  const uint64_t now_us = mi_now_us();
  evt.timestamp_us = (mi_start_us == 0 ? 0 : (now_us - mi_start_us));
  evt.event_type   = (uint8_t)event_type;
  evt.alloc_count  = alloc_total;
  evt.free_count   = free_total;
  evt.delta        = (int64_t)alloc_total - (int64_t)free_total;
  events[slot] = evt;
}

static bool mi_write_csv(uint64_t count) {
  if (mi_log_csv_path == NULL || mi_log_csv_path[0] == '\0') {
    return false;
  }
  FILE* fp = fopen(mi_log_csv_path, "w");
  if (fp == NULL) {
    return false;
  }
  fputs("timestamp_us,event_type,alloc_count,free_count,delta\n", fp);
  for (uint64_t i = 0; i < count && i < MI_MAX_EVENTS; ++i) {
    const struct mi_event* evt = &events[i];
    fprintf(fp, "%llu,%u,%llu,%llu,%lld\n",
            (unsigned long long)evt->timestamp_us,
            (unsigned int)evt->event_type,
            (unsigned long long)evt->alloc_count,
            (unsigned long long)evt->free_count,
            (long long)evt->delta);
  }
  fclose(fp);
  return true;
}

static bool mi_write_raw(uint64_t count) {
  if (mi_log_raw_path == NULL || mi_log_raw_path[0] == '\0') {
    return false;
  }
  FILE* fp = fopen(mi_log_raw_path, "wb");
  if (fp == NULL) {
    return false;
  }
  if (count > MI_MAX_EVENTS) {
    count = MI_MAX_EVENTS;
  }
  if (count > 0) {
    fwrite(events, sizeof(struct mi_event), count, fp);
  }
  fclose(fp);
  return true;
}

void mi_event_log_flush(void) {
  uint64_t count = atomic_load_explicit(&event_index, memory_order_relaxed);
  if (count > MI_MAX_EVENTS) {
    count = MI_MAX_EVENTS;
  }
  const bool wrote_csv = mi_write_csv(count);
  const bool wrote_raw = mi_write_raw(count);
  if (wrote_csv) {
    fprintf(stderr, "[mi_event_log] CSV saved at %s (%llu events)\n",
            mi_log_csv_path,
            (unsigned long long)count);
  }
  if (wrote_raw) {
    fprintf(stderr, "[mi_event_log] RAW saved at %s (%llu events)\n",
            mi_log_raw_path,
            (unsigned long long)count);
  }
}

void mi_event_log_set_paths(const char* csv_path, const char* raw_path) {
  mi_log_csv_path = csv_path;
  mi_log_raw_path = raw_path;
}
