#include "bridge_packet.h"
#include "bridge_state.h"
#include "bridge_fault.h"
#include "remote_decoder.h"
#include "event_bus.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

int event_bus_stub_count(void);
void event_bus_stub_reset(void);

static int g_fail;

#define EXPECT(cond)                                                           \
  do {                                                                         \
    if (!(cond)) {                                                             \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);          \
      g_fail++;                                                                \
    }                                                                          \
  } while (0)

static void test_packet_roundtrip(void) {
  bridge_packet_t in = {0}, out = {0};
  uint8_t buf[16];
  in.type = PKT_MOTION;
  in.seq = 7;
  in.u.motion.dx = -12;
  in.u.motion.dy = 34;
  in.u.motion.buttons = 0;
  in.u.motion.wheel = -1;
  size_t n = bridge_packet_encode(&in, buf, sizeof(buf));
  EXPECT(n == 9);
  EXPECT(bridge_packet_validate(buf, n));
  EXPECT(bridge_packet_parse(buf, n, &out));
  EXPECT(out.type == PKT_MOTION && out.seq == 7);
  EXPECT(out.u.motion.dx == -12 && out.u.motion.dy == 34);
  EXPECT(out.u.motion.wheel == -1);

  uint8_t bad[] = {0xFF, 0x00};
  EXPECT(!bridge_packet_validate(bad, sizeof(bad)));
  uint8_t trunc[] = {PKT_BUTTON, 1, 0x10}; /* missing bytes */
  EXPECT(!bridge_packet_validate(trunc, sizeof(trunc)));

  in.type = PKT_BUTTON;
  in.u.button.code = 0x0040;
  in.u.button.down = 1;
  n = bridge_packet_encode(&in, buf, sizeof(buf));
  EXPECT(n == 5);
  EXPECT(bridge_packet_parse(buf, n, &out));
  EXPECT(out.u.button.code == 0x0040 && out.u.button.down == 1);
}

static void test_bridge_state(void) {
  bridge_state_init();
  EXPECT(bridge_state_overall() == BRIDGE_WAIT_MAC);
  bridge_state_set_mac(MAC_READY);
  EXPECT(bridge_state_overall() == BRIDGE_WAIT_REMOTE);
  bridge_state_set_remote(REM_WAIT_MAC);
  EXPECT(bridge_state_overall() == BRIDGE_WAIT_REMOTE);
  bridge_state_set_remote(REM_READY);
  EXPECT(bridge_state_overall() == BRIDGE_STREAMING);
  bridge_state_set_remote(REM_RECOVERING);
  EXPECT(bridge_state_overall() == BRIDGE_RECOVERING);
  uint32_t a = bridge_session_bump_mac();
  uint32_t b = bridge_session_bump_mac();
  EXPECT(b == a + 1);
}

static void test_decoder_buttons(void) {
  event_bus_init();
  event_bus_stub_reset();
  remote_decoder_t *d = remote_decoder_create();
  EXPECT(d != NULL);
  remote_decoder_reset(d);

  uint8_t fd[19] = {0};
  fd[0] = 0xFD;
  /* button BE at 16..17 */
  fd[16] = 0x00;
  fd[17] = 0x40;
  fd[18] = 0;
  remote_decoder_on_fd(d, fd, sizeof(fd));

  bus_event_t ev;
  int saw_down = 0;
  while (event_bus_take(&ev, 0)) {
    if (ev.type == BUS_BUTTON && ev.u.button.code == 0x0040 && ev.u.button.down)
      saw_down = 1;
  }
  EXPECT(saw_down == 1);

  fd[16] = fd[17] = 0;
  remote_decoder_on_fd(d, fd, sizeof(fd));
  int saw_up = 0;
  while (event_bus_take(&ev, 0)) {
    if (ev.type == BUS_BUTTON && ev.u.button.code == 0x0040 && !ev.u.button.down)
      saw_up = 1;
  }
  EXPECT(saw_up == 1);

  /* short frame rejected */
  remote_decoder_on_fd(d, fd, 10);
  EXPECT(event_bus_stub_count() == 0);
  free(d);
}

/* kBiasWarmup in remote_decoder.c, plus margin. */
static const int kCalibrationFrames = 80;

static void fd_set_gyro(uint8_t fd[19], int16_t gx, int16_t gy, int16_t gz) {
  int16_t gyro[3] = {gx, gy, gz};
  for (int i = 0; i < 3; i++) {
    uint16_t raw = (uint16_t)gyro[i];
    fd[4 + i * 2] = (uint8_t)(raw >> 8);
    fd[5 + i * 2] = (uint8_t)raw;
  }
}

static void fd_set_accel(uint8_t fd[19], int16_t ax, int16_t ay, int16_t az) {
  int16_t accel[3] = {ax, ay, az};
  for (int i = 0; i < 3; i++) {
    uint16_t raw = (uint16_t)accel[i];
    fd[10 + i * 2] = (uint8_t)(raw >> 8);
    fd[11 + i * 2] = (uint8_t)raw;
  }
}

static void drain_motion(long *dx, long *dy) {
  bus_event_t ev;
  while (event_bus_take(&ev, 0)) {
    if (ev.type == BUS_MOTION) {
      *dx += ev.u.motion.dx;
      *dy += ev.u.motion.dy;
    }
  }
}

static void test_decoder_roll_compensation(void) {
  event_bus_init();
  remote_decoder_t *d = remote_decoder_create();
  EXPECT(d != NULL);
  remote_decoder_reset(d);
  uint8_t fd[19] = {0};
  fd[0] = 0xFD;

  fd_set_accel(fd, 0, 0, 1000);
  for (int i = 0; i < kCalibrationFrames; i++) {
    fd_set_gyro(fd, 0, 0, 0);
    remote_decoder_on_fd(d, fd, sizeof(fd));
  }

  long up_dx = 0, up_dy = 0;
  for (int i = 0; i < 30; i++) {
    fd_set_gyro(fd, 500, 0, 900);
    remote_decoder_on_fd(d, fd, sizeof(fd));
    drain_motion(&up_dx, &up_dy);
  }

  /* Roll 180 degrees: gravity and local gyro X/Z both reverse. */
  fd_set_accel(fd, 0, 0, -1000);
  for (int i = 0; i < 100; i++) {
    fd_set_gyro(fd, 0, 0, 0);
    remote_decoder_on_fd(d, fd, sizeof(fd));
    long ignored_x = 0, ignored_y = 0;
    drain_motion(&ignored_x, &ignored_y);
  }
  long down_dx = 0, down_dy = 0;
  for (int i = 0; i < 30; i++) {
    fd_set_gyro(fd, -500, 0, -900);
    remote_decoder_on_fd(d, fd, sizeof(fd));
    drain_motion(&down_dx, &down_dy);
  }

  EXPECT(up_dx > 0 && up_dy > 0);
  EXPECT(down_dx > 0 && down_dy > 0);
  EXPECT(labs(up_dx - down_dx) < labs(up_dx) / 5 + 2);
  EXPECT(labs(up_dy - down_dy) < labs(up_dy) / 5 + 2);
  free(d);
}

static void test_decoder_reconnect_calibration(void) {
  event_bus_init();
  remote_decoder_t *d = remote_decoder_create();
  EXPECT(d != NULL);
  remote_decoder_reset(d);
  uint8_t fd[19] = {0};
  fd[0] = 0xFD;

  /* Hard boot + waving: no motion (would drift with a provisional bias). */
  for (int i = 0; i < 80; i++) {
    int16_t v = (i & 1) ? 500 : -500;
    fd_set_gyro(fd, v, 0, (int16_t)-v);
    remote_decoder_on_fd(d, fd, sizeof(fd));
  }
  EXPECT(event_bus_stub_count() == 0);

  /* Hold still → calibrate → motion works. */
  for (int i = 0; i < 60; i++) {
    fd_set_gyro(fd, 100, -20, 80);
    remote_decoder_on_fd(d, fd, sizeof(fd));
  }
  bus_event_t ev;
  while (event_bus_take(&ev, 0)) {
  }
  fd_set_gyro(fd, 900, -20, 900);
  remote_decoder_on_fd(d, fd, sizeof(fd));
  int saw_motion = 0;
  while (event_bus_take(&ev, 0)) {
    if (ev.type == BUS_MOTION && (ev.u.motion.dx || ev.u.motion.dy)) saw_motion = 1;
  }
  EXPECT(saw_motion == 1);

  /* Soft reconnect: preserve committed bias and accept motion immediately. */
  remote_decoder_reset_session(d);
  saw_motion = 0;
  fd_set_gyro(fd, 900, -20, 900);
  remote_decoder_on_fd(d, fd, sizeof(fd));
  while (event_bus_take(&ev, 0)) {
    if (ev.type == BUS_MOTION && (ev.u.motion.dx || ev.u.motion.dy)) saw_motion = 1;
  }
  EXPECT(saw_motion == 1);
  free(d);
}

/* Slow diagonal motion must keep its direction. A per-axis deadzone gave each axis
 * a different gain, flattening the path toward the dominant axis and producing a
 * visible zigzag; the radial deadzone must hold the dx:dy ratio instead. */
static void test_decoder_slow_diagonal_direction(void) {
  event_bus_init();
  remote_decoder_t *d = remote_decoder_create();
  EXPECT(d != NULL);
  remote_decoder_reset(d);
  uint8_t fd[19] = {0};
  fd[0] = 0xFD;

  /* Settle the bias at zero. */
  for (int i = 0; i < kCalibrationFrames; i++) {
    fd_set_gyro(fd, 0, 0, 0);
    remote_decoder_on_fd(d, fd, sizeof(fd));
  }

  /* gz drives dx, gx drives dy. Hold a steady 2:1 slope just above the deadzone. */
  const int16_t gz = 80, gx = 40;
  long sum_dx = 0, sum_dy = 0;
  for (int i = 0; i < 400; i++) {
    fd_set_gyro(fd, gx, 0, gz);
    remote_decoder_on_fd(d, fd, sizeof(fd));
  }
  bus_event_t ev;
  while (event_bus_take(&ev, 0)) {
    if (ev.type == BUS_MOTION) {
      sum_dx += ev.u.motion.dx;
      sum_dy += ev.u.motion.dy;
    }
  }
  EXPECT(sum_dx != 0 && sum_dy != 0);
  /* Both axes move, and the 2:1 input slope survives within 10%. */
  double ratio = (double)sum_dx / (double)sum_dy;
  EXPECT(ratio > 1.8 && ratio < 2.2);
  free(d);
}

static long decoder_initial_flick_response(float threshold) {
  event_bus_init();
  event_bus_stub_reset();
  remote_decoder_t *d = remote_decoder_create();
  remote_decoder_reset(d);
  remote_decoder_set_sens(d, 0.045f, threshold, 28.0f);
  remote_decoder_set_tremor(d, 1.0f);
  uint8_t fd[19] = {0};
  fd[0] = 0xFD;
  for (int i = 0; i < kCalibrationFrames; i++) {
    fd_set_gyro(fd, 0, 0, 0);
    remote_decoder_on_fd(d, fd, sizeof(fd));
  }

  long sum_dx = 0, sum_dy = 0;
  for (int i = 0; i < 3; i++) {
    fd_set_gyro(fd, 0, 0, 900);
    remote_decoder_on_fd(d, fd, sizeof(fd));
    drain_motion(&sum_dx, &sum_dy);
  }
  free(d);
  return labs(sum_dx);
}

static void test_decoder_threshold_opens_fast_response(void) {
  long adaptive = decoder_initial_flick_response(100.0f);
  long filtered = decoder_initial_flick_response(2000.0f);
  EXPECT(adaptive > filtered);
  EXPECT(filtered > 0);
}

static void test_fault_inject(void) {
  bridge_fault_reset();
  bridge_fault()->drop_next_tx = 2;
  EXPECT(bridge_fault_should_drop_tx() == true);
  EXPECT(bridge_fault_should_drop_tx() == true);
  EXPECT(bridge_fault_should_drop_tx() == false);
  bridge_fault()->force_tx_overflow = 1;
  EXPECT(bridge_fault_should_overflow() == true);
  EXPECT(bridge_fault_should_overflow() == false);
}

int main(void) {
  test_packet_roundtrip();
  test_bridge_state();
  test_decoder_buttons();
  test_decoder_reconnect_calibration();
  test_decoder_roll_compensation();
  test_decoder_slow_diagonal_direction();
  test_decoder_threshold_opens_fast_response();
  test_fault_inject();
  if (g_fail) {
    fprintf(stderr, "%d assertion(s) failed\n", g_fail);
    return 1;
  }
  printf("host_tests: OK\n");
  return 0;
}
