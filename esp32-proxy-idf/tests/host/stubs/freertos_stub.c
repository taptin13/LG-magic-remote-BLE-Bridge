#include "freertos/queue.h"
#include "freertos/semphr.h"
#include <stdlib.h>
#include <string.h>

struct host_queue {
  unsigned length, item_size, head, count;
  unsigned char *data;
};

struct host_sem { int available; };

QueueHandle_t xQueueCreate(unsigned length, unsigned item_size) {
  struct host_queue *q = calloc(1, sizeof(*q));
  if (!q) return NULL;
  q->data = calloc(length, item_size);
  if (!q->data) { free(q); return NULL; }
  q->length = length;
  q->item_size = item_size;
  return q;
}

int xQueueSend(QueueHandle_t q, const void *item, TickType_t wait) {
  (void)wait;
  if (!q || !item || q->count >= q->length) return pdFALSE;
  unsigned tail = (q->head + q->count) % q->length;
  memcpy(q->data + tail * q->item_size, item, q->item_size);
  q->count++;
  return pdTRUE;
}

int xQueueReceive(QueueHandle_t q, void *item, TickType_t wait) {
  (void)wait;
  if (!q || !item || q->count == 0) return pdFALSE;
  memcpy(item, q->data + q->head * q->item_size, q->item_size);
  q->head = (q->head + 1) % q->length;
  q->count--;
  return pdTRUE;
}

static SemaphoreHandle_t sem_create(int available) {
  SemaphoreHandle_t sem = calloc(1, sizeof(*sem));
  if (sem) sem->available = available;
  return sem;
}

SemaphoreHandle_t xSemaphoreCreateBinary(void) { return sem_create(0); }
SemaphoreHandle_t xSemaphoreCreateMutex(void) { return sem_create(1); }
int xSemaphoreGive(SemaphoreHandle_t sem) {
  if (!sem) return pdFALSE;
  sem->available = 1;
  return pdTRUE;
}
int xSemaphoreTake(SemaphoreHandle_t sem, TickType_t wait) {
  (void)wait;
  if (!sem || !sem->available) return pdFALSE;
  sem->available = 0;
  return pdTRUE;
}
