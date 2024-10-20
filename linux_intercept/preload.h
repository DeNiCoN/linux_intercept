#pragma once

extern void *intercept_shared_mem;

typedef struct intercept_header {
  void *child_memory_position;
} intercept_header;
