// Passive Nintendo Switch Pro IMU reports (#296). No commands or calibration writes: macOS owns the device and enables report 0x30.
// Layout / nominal scales: dekuNukem/Nintendo_Switch_Reverse_Engineering, imu_sensor_notes.md. The LSM6DS3's ±2000 dps sensitivity is 70 mdps/count,
// not 4000/65536 (61 mdps/count). Factory offsets / sensitivity are not available without SPI commands; never learn an offset from a slow deliberate turn.
// Samples follow byte order, 5 ms apart, as in Linux hid-nintendo and the protocol notes. SDL reverses them; hardware confirmation remains open.
// Gyro zero: the raw rate carries the sensor's offset (tenths of a degree a second), which the Switch takes off with the pad's stored calibration and these passive reports cannot
// read, so the camera of a game that aims by motion drifted steadily (Ocarina of Time: a slow turn to the left). While the pad lies still for PRO_BIAS_SAMPLES samples (1 s: every
// axis under PRO_BIAS_MAX, the window's spread under PRO_BIAS_SPREAD, |acc| within 5 % of 1 G and steady within 0.02 G) the window's mean becomes the zero and is taken off every
// sample after; the next second of stillness replaces it. A turn breaks the window; a slow turn about the vertical that stays under 2 °/s for a whole second would be learned,
// and un-learned at the next rest: bounded by PRO_BIAS_MAX, so never a large error
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <math.h>

enum { PRO_MOTION_PERIOD_NS = 5000000, PRO_MOTION_STALE_NS = 300000000 };
enum { PRO_BIAS_SAMPLES = 200 };
#define PRO_BIAS_MAX (2.0f * (float)M_PI / 180)      /* a zero this size at most, rad/s */
#define PRO_BIAS_SPREAD (0.5f * (float)M_PI / 180)   /* the window's min-to-max spread per axis, rad/s */
typedef struct { int live, seen; uint8_t counter; uint64_t received;
                 int still, bias_set, bias_logged; float sum[3], lo[3], hi[3], acc0[3], bias[3]; } pro_motion;   // still: samples of the current rest window; bias: the zero taken off
typedef struct { float acc[3], rot[3]; uint64_t ns; } pro_motion_sample;
static inline int pro_motion_player(int devices, int controllers, int player) {
    // GameController has no public per-controller HID identity. Only one physical Pro and one GC Pro can be paired without guessing.
    return devices == 1 && controllers == 1 ? player : -1;
}
// One raw sample's rest window: extends it while the pad is still, learns the zero at PRO_BIAS_SAMPLES, resets it on motion; then takes the zero off rot
static inline void pro_motion_zero(pro_motion *s, const float acc[3], float rot[3]) {
    float an = sqrtf(acc[0] * acc[0] + acc[1] * acc[1] + acc[2] * acc[2]);
    int quiet = fabsf(an - 1) < 0.05f;
    for (int i = 0; i < 3 && quiet; i++) {
        quiet = fabsf(rot[i]) < PRO_BIAS_MAX;
        if (quiet && s->still) quiet = fabsf(acc[i] - s->acc0[i]) < 0.02f && rot[i] > s->hi[i] - PRO_BIAS_SPREAD && rot[i] < s->lo[i] + PRO_BIAS_SPREAD;
    }
    if (!quiet) s->still = 0;
    else {
        if (!s->still) for (int i = 0; i < 3; i++) { s->acc0[i] = acc[i]; s->lo[i] = s->hi[i] = rot[i]; s->sum[i] = 0; }
        for (int i = 0; i < 3; i++) { s->sum[i] += rot[i]; if (rot[i] < s->lo[i]) s->lo[i] = rot[i]; if (rot[i] > s->hi[i]) s->hi[i] = rot[i]; }
        if (++s->still == PRO_BIAS_SAMPLES) { for (int i = 0; i < 3; i++) s->bias[i] = s->sum[i] / PRO_BIAS_SAMPLES; s->bias_set = 1; s->still = 0; }
    }
    if (s->bias_set) for (int i = 0; i < 3; i++) rot[i] -= s->bias[i];
}
static inline int pro_motion_decode(pro_motion *s, const uint8_t *r, size_t len, uint64_t now, pro_motion_sample out[3]) {
    if (len < 49 || r[0] != 0x30 || now < 2 * PRO_MOTION_PERIOD_NS) return 0;
    if (s->seen && (now < s->received || now - s->received > PRO_MOTION_STALE_NS)) *s = (pro_motion){0};
    if (s->seen && s->counter == r[1]) return 0;   // repeated report, not another three samples
    int16_t v[3][6]; int data = 0;
    for (int k = 0; k < 3; k++) for (int i = 0; i < 6; i++) {
        const uint8_t *b = r + 13 + 12 * k + 2 * i;
        v[k][i] = (int16_t)((uint16_t)b[0] | (uint16_t)b[1] << 8); data |= v[k][i] != 0;
    }
    s->seen = 1; s->counter = r[1]; s->received = now;
    if (!s->live && !data) return 0;   // an advertised but empty stream is not a motion source
    s->live = 1;
    const float g = 1.f / 4096.f, rad = 0.070f * (float)M_PI / 180.f;
    for (int k = 0; k < 3; k++) {
        // Raw axes: x toward shoulders, y left, z out of face; acceleration is specific force. Switch: x right, y forward, gravity down.
        out[k] = (pro_motion_sample){{v[k][1] * g, -v[k][0] * g, -v[k][2] * g},
                                    {-v[k][4] * rad, v[k][3] * rad, v[k][5] * rad}, now - (uint64_t)(2 - k) * PRO_MOTION_PERIOD_NS};
        pro_motion_zero(s, out[k].acc, out[k].rot);
    }
    return 3;
}
