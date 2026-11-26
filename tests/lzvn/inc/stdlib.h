#pragma once
#include <stddef.h>
#define NULL ((void*)0)
void *malloc(size_t);
void free(void*);
void *calloc(size_t,size_t);
void *realloc(void*,size_t);
int abs(int);
long labs(long);
