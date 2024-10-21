#include "preload.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

void *intercept_shared_mem;
int created = 0;
int page_size = 0;

void __attribute__((constructor)) init() {
  puts("I need to run before main()!");

  page_size = getpagesize();

  int fd = shm_open("/linux_intercept", O_RDWR, 0777);
  if (fd == -1) {
    fprintf(stderr, "Failed to open shared memory: %s\n", strerror(errno));
    return;
  }

  intercept_shared_mem =
      mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);

  if (intercept_shared_mem == MAP_FAILED) {
    fprintf(stderr, "Failed mmap shared memory: %s\n", strerror(errno));
  }

  intercept_header *header = intercept_shared_mem;
  header->child_memory_position = intercept_shared_mem;
  fprintf(stderr, "Changing child_memory_position to %p\n",
          intercept_shared_mem);
}

void __attribute__((destructor)) deinit() {
  if (created) {
    if (shm_unlink("/linux_intercept") == -1) {
      fprintf(stderr, "Failed shm_unlink: %s\n", strerror(errno));
    }
  }

  if (munmap(intercept_shared_mem, page_size) == -1) {
    fprintf(stderr, "Failed munmap: %s\n", strerror(errno));
  }
}
