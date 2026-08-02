#pragma once
#include "FreeRTOS.h"

SemaphoreHandle_t xSemaphoreCreateBinary(void);
SemaphoreHandle_t xSemaphoreCreateMutex(void);
int xSemaphoreGive(SemaphoreHandle_t sem);
int xSemaphoreTake(SemaphoreHandle_t sem, TickType_t wait);
