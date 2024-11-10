#pragma once

#include "stddef.h"
extern void *intercept_shared_mem;

typedef struct intercept_pid_entry {
  size_t id;
  size_t pid;
  size_t address;
} intercept_pid_entry;

typedef struct intercept_header {
  size_t processes;
  intercept_pid_entry entries[256];
} intercept_header;
