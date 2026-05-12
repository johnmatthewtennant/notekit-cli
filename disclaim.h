#ifndef NOTEKIT_DISCLAIM_H
#define NOTEKIT_DISCLAIM_H

#include <stddef.h>
#include <sys/types.h>

void notekit_disclaim_if_needed(int argc, char *argv[]);
pid_t notekit_responsible_pid(void);
const void *notekit_embedded_info_plist_bytes(size_t *length);

#endif
