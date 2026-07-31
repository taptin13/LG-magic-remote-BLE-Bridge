# Host unit tests — no ESP-IDF / FreeRTOS required
# Usage: make test

CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -O1 -DHOST_TEST -DBRIDGE_FAULT_INJECT=1
ROOT := ../..
MAIN := $(ROOT)/main
BUILD := build

SRCS := \
  $(MAIN)/bridge_packet.c \
  $(MAIN)/bridge_state.c \
  $(MAIN)/bridge_fault.c \
  $(MAIN)/remote_decoder.c \
  stubs/event_bus_stub.c \
  test_main.c

INCLUDES := -I$(MAIN) -Istubs

.PHONY: all test clean
all: $(BUILD)/host_tests

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/host_tests: $(SRCS) | $(BUILD)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $(SRCS) -lm

test: $(BUILD)/host_tests
	./$(BUILD)/host_tests

clean:
	rm -rf $(BUILD)
