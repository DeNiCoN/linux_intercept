#include "preload.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <semaphore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#define _GNU_SOURCE
#include <unistd.h>

void *intercept_shared_mem;
int created = 0;
int page_size = 0;
int locked_semaphore = 0;

sem_t *semptr;

char *sem_name = 0;
char *shmem_name = 0;

void __attribute__((constructor)) init() {
  // puts("I need to run before main()!");

  sem_name = getenv("LINUX_INTERCEPT_SEM_NAME");
  if (!sem_name) {
    fprintf(stderr, "No LINUX_INTERCEPT_SEM_NAME env variable");
    return;
  }

  shmem_name = getenv("LINUX_INTERCEPT_SHMEM_NAME");
  if (!shmem_name) {
    fprintf(stderr, "No LINUX_INTERCEPT_SHMEM_NAME env variable");
    return;
  }

  page_size = getpagesize();

  // printf("Semaphore: %s\n", sem_name);
  // printf("Shared memory: %s\n", shmem_name);
  //  TODO Lock preventing second LD_PRELOAD
  int fd = shm_open(shmem_name, O_RDWR, 0777);
  if (fd == -1) {
    fprintf(stderr, "Failed to open shared memory: %s\n", strerror(errno));
    return;
  }

  intercept_shared_mem =
      mmap(NULL, page_size * 16, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);

  if (intercept_shared_mem == MAP_FAILED) {
    fprintf(stderr, "Failed mmap shared memory: %s\n", strerror(errno));
  }

  intercept_header *header = intercept_shared_mem;

  semptr = sem_open(sem_name, /* name */
                    O_CREAT,  /* create the semaphore */
                    0777,     /* protection perms */
                    1);       /* initial value */

  if (semptr == (void *)-1) {
    fprintf(stderr, "Failed to open semaphore: %s\n", strerror(errno));
    return;
  }

  if (sem_wait(semptr) < 0) {
    if (errno == EAGAIN) {
      // fprintf(stderr, "Semaphore is locked: %s\n", strerror(errno));
      return;
    } else {
      fprintf(stderr, "Unexpected error in trywait: %s\n", strerror(errno));
      return;
    }
  }
  locked_semaphore = 1;

  if (header->processes >=
      sizeof(header->entries) / sizeof(header->entries[0])) {
    fprintf(stderr, "Out of process capacity\n");

    if (sem_post(semptr) < 0) {
      fprintf(stderr, "Failed to increment semaphore: %s\n", strerror(errno));
      return;
    }

    exit(1);
  }

  const pid_t pid = getpid();
  int i;
  for (i = 0; i < header->processes; i++) {
    if (header->entries[i].pid == pid) {
      header->entries[i].address = (size_t)intercept_shared_mem;
      break;
    }
  }

  if (i == header->processes) {
    fprintf(stderr, "Adding new %ldth entry for pid %d gid %d\n",
            header->processes, getpid(), getgid());
    intercept_pid_entry entry = {
        .id = header->processes,
        .pid = getpid(),
        .address = (size_t)intercept_shared_mem,
    };
    header->entries[header->processes] = entry;
    header->processes += 1;
  } else {
    fprintf(stderr, "Changed %dth entry for pid %d gid %d\n", i, getpid(),
            getgid());
  }

  if (sem_post(semptr) < 0) {
    fprintf(stderr, "Failed to increment semaphore: %s\n", strerror(errno));
    return;
  }

  locked_semaphore = 0;
}

void __attribute__((destructor)) deinit() {
  if (locked_semaphore == 1) {
    if (sem_post(semptr) < 0) {
      fprintf(stderr, "Failed to increment semaphore: %s\n", strerror(errno));
      return;
    }
  }

  if (created) {
    if (shm_unlink(shmem_name) == -1) {
      fprintf(stderr, "Failed shm_unlink: %s\n", strerror(errno));
    }
  }

  if (munmap(intercept_shared_mem, page_size) == -1) {
    fprintf(stderr, "Failed munmap: %s\n", strerror(errno));
  }
}
