// The Mac keyboard's map to the Switch controls (Nintendo layout), as one table: front_mac.m's on_key presses the buttons and moves the sticks from it, and the
// Controls panel (controls_mac.h, Window > Show Controls) lists it, so what the panel says a key does is what the key does. tests/t_controls_mac.m checks the
// table: every Switch button and stick direction has exactly one key, and no key means two things. Key codes are the Mac's virtual key codes (kVK_* in Carbon's
// Events.h), which name a key by its place on the keyboard, so the map is the same on every layout.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "dm_input.h"

// Where the panel lists a key, in this order
enum { KM_STICKS, KM_FACE, KM_SHOULDERS, KM_PLUS_MINUS, KM_STICK_PRESS, KM_SHAKE, KM_GROUPS };
static const char *const km_group_names[KM_GROUPS] = {"Sticks and D-pad", "Face buttons", "Shoulders and triggers", "+ and −", "Stick presses", "Shake"};
// A stick direction, and the stick: 0 the left one, 1 the right one
enum { KM_LEFT, KM_UP, KM_RIGHT, KM_DOWN, KM_DIRS };
enum { KM_LSTICK, KM_RSTICK, KM_STICKS_N };

typedef struct {
    unsigned short code;   // the key
    uint8_t shift;         // 1: with Shift held (the arrows' second meaning, the right stick)
    uint8_t group;         // KM_STICKS..KM_SHAKE
    int8_t stick;          // KM_LSTICK or KM_RSTICK for a stick direction, -1 for a button
    int8_t dir;            // a stick's KM_LEFT..KM_DOWN
    uint64_t bit;          // a button's DM_BTN_* bit (DM_BTN_SHAKE: the controller is shaken while the key is held)
    const char *control;   // the Switch control as the panel names it: the keys of one control in one group share a row, in this order
    const char *key;       // the key as the panel names it
} km_key;

static const km_key km_keys[] = {
    {13, 0, KM_STICKS, KM_LSTICK, KM_UP, 0, "Left stick", "W"},
    {0, 0, KM_STICKS, KM_LSTICK, KM_LEFT, 0, "Left stick", "A"},
    {1, 0, KM_STICKS, KM_LSTICK, KM_DOWN, 0, "Left stick", "S"},
    {2, 0, KM_STICKS, KM_LSTICK, KM_RIGHT, 0, "Left stick", "D"},
    // An arrow pressed with Shift held is the right stick until it is released, whatever Shift does meanwhile; without Shift, the D-pad. The keyboard had no
    // right stick: a 3D game's camera could be turned only with a controller (Donkey Kong Bananza)
    {126, 1, KM_STICKS, KM_RSTICK, KM_UP, 0, "Right stick", "↑"},
    {123, 1, KM_STICKS, KM_RSTICK, KM_LEFT, 0, "Right stick", "←"},
    {125, 1, KM_STICKS, KM_RSTICK, KM_DOWN, 0, "Right stick", "↓"},
    {124, 1, KM_STICKS, KM_RSTICK, KM_RIGHT, 0, "Right stick", "→"},
    {126, 0, KM_STICKS, -1, 0, DM_BTN_UP, "D-pad", "↑"},
    {123, 0, KM_STICKS, -1, 0, DM_BTN_LEFT, "D-pad", "←"},
    {125, 0, KM_STICKS, -1, 0, DM_BTN_DOWN, "D-pad", "↓"},
    {124, 0, KM_STICKS, -1, 0, DM_BTN_RIGHT, "D-pad", "→"},
    {38, 0, KM_FACE, -1, 0, DM_BTN_A, "A", "J"},
    {40, 0, KM_FACE, -1, 0, DM_BTN_B, "B", "K"},
    {32, 0, KM_FACE, -1, 0, DM_BTN_X, "X", "U"},
    {34, 0, KM_FACE, -1, 0, DM_BTN_Y, "Y", "I"},
    {12, 0, KM_SHOULDERS, -1, 0, DM_BTN_L, "L", "Q"},
    {14, 0, KM_SHOULDERS, -1, 0, DM_BTN_R, "R", "E"},
    {6, 0, KM_SHOULDERS, -1, 0, DM_BTN_ZL, "ZL", "Z"},
    {8, 0, KM_SHOULDERS, -1, 0, DM_BTN_ZR, "ZR", "C"},
    {36, 0, KM_PLUS_MINUS, -1, 0, DM_BTN_PLUS, "+", "Return"},
    {48, 0, KM_PLUS_MINUS, -1, 0, DM_BTN_MINUS, "−", "Tab"},
    {3, 0, KM_STICK_PRESS, -1, 0, DM_BTN_LS, "Left stick", "F"},
    {5, 0, KM_STICK_PRESS, -1, 0, DM_BTN_RS, "Right stick", "G"},
    {49, 0, KM_SHAKE, -1, 0, DM_BTN_SHAKE, "Hold to shake", "Space"},
};
#define KM_KEYS (sizeof km_keys / sizeof km_keys[0])

// The button a key presses without Shift: its DM_BTN_* bit (DM_BTN_SHAKE for the shake), 0 for a stick key or a key the map does not have
static inline uint64_t km_button(unsigned short code) {
    for (size_t i = 0; i < KM_KEYS; i++) if (km_keys[i].code == code && !km_keys[i].shift && km_keys[i].stick < 0) return km_keys[i].bit;
    return 0;
}
// The direction a key moves a stick in (KM_LEFT..KM_DOWN), -1 when it does not move that stick. The right stick's keys are the arrows with Shift held: the
// caller decides when Shift counts (on_key: when the key goes down)
static inline int km_stick_dir(unsigned short code, int stick) {
    for (size_t i = 0; i < KM_KEYS; i++) if (km_keys[i].code == code && km_keys[i].stick == stick) return km_keys[i].dir;
    return -1;
}
