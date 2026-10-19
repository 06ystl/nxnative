// Front end (Mac keyboard / iOS touchscreen) -> nn::hid input state. Button bits match nn::hid::NpadButton:
// A0 B1 X2 Y3 StickL4 StickR5 L6 R7 ZL8 ZR9 Plus10 Minus11 Left12 Up13 Right14 Down15; sticks ±32767.
#pragma once
#include <stdint.h>
// Button bits (= nn::hid::NpadButton bit order; the DM_KEYS key-name table in hle_hid.c is generated from here). Frontends always compose buttons from these names.
enum {
    DM_BTN_A = 1u << 0, DM_BTN_B = 1u << 1, DM_BTN_X = 1u << 2, DM_BTN_Y = 1u << 3,
    DM_BTN_LS = 1u << 4, DM_BTN_RS = 1u << 5, DM_BTN_L = 1u << 6, DM_BTN_R = 1u << 7,
    DM_BTN_ZL = 1u << 8, DM_BTN_ZR = 1u << 9, DM_BTN_PLUS = 1u << 10, DM_BTN_MINUS = 1u << 11,
    DM_BTN_LEFT = 1u << 12, DM_BTN_UP = 1u << 13, DM_BTN_RIGHT = 1u << 14, DM_BTN_DOWN = 1u << 15,
};
#define DM_STICK_MAX 32767
void dm_input_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry);
uint64_t dm_input_samples(void);   // Cumulative number of times the game has sampled the controller
// Independent controller channel (Mac GameController, gamepad_mac.m; DM_KEYS scripts): stored separately from keyboard / touch input. When the game reads it,
// buttons are ORed and each axis uses the value with greater magnitude. The iOS frontend merges physical and touch input before calling dm_input_set.
void dm_pad_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry);

// nn::hid::SixAxisSensorState ABI. Angular velocity and angle use revolutions;
// acceleration is in g, delta_time in nanoseconds. Direction is a 3x3 basis.
typedef struct {
    uint64_t delta_time, sampling;
    float acceleration[3], angular_velocity[3], angle[3], direction[3][3];
    uint32_t attributes, reserved;
} dm_sixaxis_state;
_Static_assert(sizeof(dm_sixaxis_state) == 0x60, "SixAxisSensorState ABI");
// Optional frontend motion source, independent of buttons/sticks. Returns 0
// when unavailable/stale; read-only snapshots never integrate the same sample twice.
extern int (*dm_motion_read)(dm_sixaxis_state *state, int fusion);

// nn::hid::VibrationValue ABI: low/high amplitude (0..1) and frequency (Hz).
// A frontend installs these before guest startup. Without a sink the original
// no-vibration-device behavior remains. The send callback only publishes a snapshot;
// it must not reenter HID or block on hardware.
typedef struct { float amplitude_low, frequency_low, amplitude_high, frequency_high; } dm_vibration_value;
_Static_assert(sizeof(dm_vibration_value) == 16, "VibrationValue ABI");
extern void (*dm_vibration_send)(unsigned side, const dm_vibration_value *value);
extern void (*dm_vibration_shutdown)(void);

// Optional diagnostic DM_HID_RECEIPT_LOG=<writable JSONL path>: received samples of real GetNpadState returns.
// Fields read_start_ns/time_ns use the same host now_ns(); the front-end publish window must use the same helper, and a read interval that spans a publish must not be force-matched.
// State changes + at most one activity witness per second, limit_reached after 1024 entries; no file is written when the environment variable is not set.
// The actual return includes id/style/sampling/buttons/four axes/attributes/script_mask; front-end output is not treated as received.
// No new line does not prove that a blank touch point was read; a valid connection / sampling activity / evidence from the original UI and command packets is required; the log has IO overhead and is not used for timing.

// Private skill-aim-v1: takes only paired received samples of the right axis that GetNpad has actually returned, not values the front end has not yet had consumed.
void dm_input_sampled_right(int32_t *rx,int32_t *ry);

// Controller state injection point: called after GetNpadState has filled in the original state and before the pseudo-key override. The Mac host touch point script (touch_mac.c, Mac only, kept out of the iOS app by the _mac convention) registers at startup; iOS does not carry that file and it stays empty
extern void (*dm_pad_hook)(uint64_t now, uint64_t *buttons, int32_t *lx, int32_t *ly, int32_t *rx, int32_t *ry);
