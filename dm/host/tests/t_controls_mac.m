// The Mac key map (keymap_mac.h) and the Controls panel built from it (controls_mac.h), without a game or a window: the map is the one the docs and front_mac.m's
// header describe, every Switch button and stick direction has exactly one key and no key means two things, the panel lists every key of the map under its control
// and group and the menu bar's shortcuts as the menu shows them, its labels never take the keyboard, and the panel itself never becomes key.
// DM_CONTROLS_CAPTURE=<folder> also draws the panel's content into controls-panel.png there (the pull request's screenshot), in an offscreen window.
#import "../controls_mac.h"
#include <stdio.h>

static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)

static void texts(NSView *v, NSMutableArray<NSString *> *out) {
    if ([v isKindOfClass:NSTextField.class]) [out addObject:((NSTextField *)v).stringValue];
    for (NSView *s in v.subviews) texts(s, out);
}
static int takes_focus(NSView *v) {
    if (v.acceptsFirstResponder) return 1;
    for (NSView *s in v.subviews) if (takes_focus(s)) return 1;
    return 0;
}
static int has_row(NSArray<NSArray<NSString *> *> *rows, NSString *control, NSString *keys) {
    for (NSArray<NSString *> *r in rows) if (r.count == 2 && [r[0] isEqualToString:control] && [r[1] isEqualToString:keys]) return 1;
    return 0;
}
static NSMenuItem *item(NSMenu *m, NSString *title, NSString *key, NSEventModifierFlags mods) {
    NSMenuItem *it = [m addItemWithTitle:title action:@selector(terminate:) keyEquivalent:key];
    if (key.length) it.keyEquivalentModifierMask = mods;
    return it;
}

// Over a stand-in for the game's picture, in the HUD panel's dark see-through look
static void capture(NSView *content, const char *dir) {
    NSSize s = content.fittingSize, all = NSMakeSize(s.width + 40, s.height + 40);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(-100000, -100000, all.width, all.height) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSView *back = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, all.width, all.height)];
    back.wantsLayer = YES; back.layer.backgroundColor = [NSColor colorWithSRGBRed:0.25 green:0.45 blue:0.3 alpha:1].CGColor;
    NSView *hud = [[NSView alloc] initWithFrame:NSMakeRect(20, 20, s.width, s.height)];
    hud.wantsLayer = YES; hud.layer.backgroundColor = [NSColor colorWithWhite:0.08 alpha:0.82].CGColor; hud.layer.cornerRadius = 8;
    content.frame = hud.bounds; [hud addSubview:content]; [back addSubview:hud]; w.contentView = back;
    [back layoutSubtreeIfNeeded]; [back displayIfNeeded];
    NSBitmapImageRep *rep = [back bitmapImageRepForCachingDisplayInRect:back.bounds];
    if (!rep) { fprintf(stderr, "t_controls_mac: no bitmap\n"); return; }
    [back cacheDisplayInRect:back.bounds toBitmapImageRep:rep];
    NSString *path = [NSString stringWithFormat:@"%s/controls-panel.png", dir];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    printf("t_controls_mac: wrote %s (%.0fx%.0f points)\n", path.UTF8String, s.width, s.height);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];

        // The map as documented (docs/development.md, front_mac.m's header): the virtual key codes of the keys and what they did before the table
        struct { unsigned short code; uint64_t bit; } buttons[] = {
            {38, DM_BTN_A}, {40, DM_BTN_B}, {32, DM_BTN_X}, {34, DM_BTN_Y}, {3, DM_BTN_LS}, {5, DM_BTN_RS}, {12, DM_BTN_L}, {14, DM_BTN_R}, {6, DM_BTN_ZL}, {8, DM_BTN_ZR},
            {36, DM_BTN_PLUS}, {48, DM_BTN_MINUS}, {123, DM_BTN_LEFT}, {126, DM_BTN_UP}, {124, DM_BTN_RIGHT}, {125, DM_BTN_DOWN}, {49, DM_BTN_SHAKE},
        };
        for (size_t i = 0; i < sizeof buttons / sizeof buttons[0]; i++) CHECK(km_button(buttons[i].code) == buttons[i].bit, "a key presses the button the docs give it");
        CHECK(km_stick_dir(13, KM_LSTICK) == KM_UP && km_stick_dir(0, KM_LSTICK) == KM_LEFT && km_stick_dir(1, KM_LSTICK) == KM_DOWN && km_stick_dir(2, KM_LSTICK) == KM_RIGHT, "WASD is the left stick");
        CHECK(km_stick_dir(126, KM_RSTICK) == KM_UP && km_stick_dir(123, KM_RSTICK) == KM_LEFT && km_stick_dir(125, KM_RSTICK) == KM_DOWN && km_stick_dir(124, KM_RSTICK) == KM_RIGHT, "the arrows are the right stick");
        CHECK(km_stick_dir(13, KM_RSTICK) < 0 && km_stick_dir(126, KM_LSTICK) < 0, "a stick key moves one stick");
        CHECK(km_button(13) == 0 && km_button(0) == 0, "a stick key presses no button");
        CHECK(km_button(53) == 0 && km_stick_dir(53, KM_LSTICK) < 0 && km_stick_dir(53, KM_RSTICK) < 0 && km_button(7) == 0, "Escape and X are not in the map");

        // Every button 0..15 and the shake: one key each; every stick direction: one key each; a key (with or without Shift) means one thing
        for (int b = 0; b <= 16; b++) {
            uint64_t bit = b < 16 ? 1ull << b : DM_BTN_SHAKE; int n = 0;
            for (size_t i = 0; i < KM_KEYS; i++) n += km_keys[i].stick < 0 && km_keys[i].bit == bit;
            CHECK(n == 1, "each button has exactly one key");
        }
        for (int st = 0; st < KM_STICKS_N; st++) for (int d = 0; d < KM_DIRS; d++) {
            int n = 0;
            for (size_t i = 0; i < KM_KEYS; i++) n += km_keys[i].stick == st && km_keys[i].dir == d;
            CHECK(n == 1, "each stick direction has exactly one key");
        }
        for (size_t i = 0; i < KM_KEYS; i++) {
            const km_key *k = &km_keys[i];
            CHECK(k->group < KM_GROUPS && k->control && *k->control && k->key && *k->key, "a key has its group, control and name");
            CHECK(k->stick < 0 ? k->bit != 0 && !k->shift : k->bit == 0 && k->dir >= 0 && k->dir < KM_DIRS, "a key is a button or a stick direction");
            CHECK(k->shift == (k->stick == KM_RSTICK), "Shift is the right stick's, and only its");
            for (size_t j = i + 1; j < KM_KEYS; j++) CHECK(!(km_keys[j].code == k->code && km_keys[j].shift == k->shift), "no key is in the map twice");
        }

        // The rows: every group in order, every key of the map in its control's row, a row of Shift keys says so; then the touchscreen and the menu's shortcuts
        NSMenu *bar = [NSMenu new], *app = [NSMenu new], *cheats = [[NSMenu alloc] initWithTitle:@"Cheats"], *win = [[NSMenu alloc] initWithTitle:@"Window"];
        [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = app;
        item(app, @"Quit The Legend of Zelda: Ocarina of Time", @"q", NSEventModifierFlagCommand);
        [bar addItemWithTitle:@"Cheats" action:nil keyEquivalent:@""].submenu = cheats;
        item(cheats, @"Show Cheats Window", @"c", NSEventModifierFlagCommand | NSEventModifierFlagShift);
        item(cheats, @"Infinite rupees", @"", 0);
        item(cheats, @"A hidden item", @"h", NSEventModifierFlagCommand).hidden = YES;
        item(cheats, @"Reload cheats", @"r", NSEventModifierFlagCommand);
        [bar addItemWithTitle:@"Window" action:nil keyEquivalent:@""].submenu = win;
        item(win, @"Enter Full Screen", @"f", NSEventModifierFlagControl | NSEventModifierFlagCommand);
        item(win, @"Show Controls", @"k", NSEventModifierFlagCommand);
        item(win, @"Upper case", @"U", NSEventModifierFlagCommand);
        NSArray<NSArray<NSString *> *> *rows = ctl_rows(bar);
        NSMutableArray<NSString *> *heads = [NSMutableArray array];
        for (NSArray<NSString *> *r in rows) if (r.count == 1) [heads addObject:r[0]];
        NSArray *want = @[@"Sticks and D-pad", @"Face buttons", @"Shoulders and triggers", @"+ and −", @"Stick presses", @"Shake", CTL_TOUCH_GROUP, CTL_MENU_GROUP];
        CHECK([heads isEqualToArray:want], "the groups, in order");
        for (size_t i = 0; i < KM_KEYS; i++) {
            const km_key *k = &km_keys[i]; NSString *head = nil; int found = 0;
            for (NSArray<NSString *> *r in rows) {
                if (r.count == 1) { head = r[0]; continue; }
                if ([head isEqualToString:@(km_group_names[k->group])] && [r[0] isEqualToString:@(k->control)]
                    && [[r[1] componentsSeparatedByString:@" "] containsObject:@(k->key)]) found++;
            }
            CHECK(found == 1, k->key);
        }
        CHECK(has_row(rows, @"Left stick", @"W A S D") && has_row(rows, @"Right stick", @"Shift + ↑ ← ↓ →") && has_row(rows, @"D-pad", @"↑ ← ↓ →"), "the sticks' and the D-pad's rows");
        CHECK(has_row(rows, @"A", @"J") && has_row(rows, @"ZR", @"C") && has_row(rows, @"−", @"Tab") && has_row(rows, @"Hold to shake", @"Space"), "a button's row");
        CHECK(has_row(rows, @"Touch and drag", @"Left mouse button"), "the touchscreen");
        NSArray *head_row = @[CTL_MENU_GROUP]; NSUInteger m = [rows indexOfObject:head_row];
        NSArray *menu_rows = m == NSNotFound ? @[] : [rows subarrayWithRange:NSMakeRange(m + 1, rows.count - m - 1)];
        NSArray *want_menu = @[@[@"Quit The Legend of Zelda: Ocarina of Time", @"⌘Q"], @[@"Show Cheats Window", @"⇧⌘C"], @[@"Reload cheats", @"⌘R"], @[@"Enter Full Screen", @"⌃⌘F"],
                               @[@"Show Controls", @"⌘K"], @[@"Upper case", @"⇧⌘U"]];
        CHECK([menu_rows isEqualToArray:want_menu], "the menu's shortcuts, in menu order, without the items that have none or are hidden");
        NSArray *bare = ctl_rows(nil); NSArray *menu_head = @[CTL_MENU_GROUP];
        CHECK(![bare containsObject:menu_head], "no menu: no shortcuts group");

        // The view: every row's text and the controllers line, compact, and nothing in it takes the keyboard
        NSView *v = ctl_view(rows);
        [v layoutSubtreeIfNeeded];
        NSMutableArray<NSString *> *t = [NSMutableArray array]; texts(v, t);
        int all = 1;
        for (NSArray<NSString *> *r in rows) for (NSString *s in r) all &= [t containsObject:s];
        CHECK(all, "the view shows every row");
        CHECK([t containsObject:CTL_PADS], "the view has the line on controllers");
        NSSize fit = v.fittingSize;
        CHECK(fit.width > 150 && fit.width < 320 && fit.height > 200 && fit.height < 600, "the panel is compact, with the game's long name in the Quit item");
        CHECK(!takes_focus(v), "nothing in the panel takes the keyboard");

        // The panel: never key or main, floating, hidden with the app, over a fullscreen game too, its content sized to fit
        NSPanel *p = ctl_panel();
        CHECK(!p.canBecomeKeyWindow && !p.canBecomeMainWindow, "the panel never becomes key or main");
        CHECK(p.floatingPanel && p.becomesKeyOnlyIfNeeded && p.hidesOnDeactivate && (p.styleMask & NSWindowStyleMaskHUDWindow), "a floating HUD panel that hides with the app");
        CHECK((p.collectionBehavior & NSWindowCollectionBehaviorFullScreenAuxiliary) != 0, "it can show over a fullscreen game");
        [p setFrameTopLeftPoint:NSMakePoint(100, 900)];
        ctl_panel_fill(p, rows);
        NSRect c = [p contentRectForFrameRect:p.frame];
        CHECK(fabs(c.size.width - fit.width) < 1 && fabs(c.size.height - fit.height) < 1 && fabs(NSMinX(p.frame) - 100) < 1 && fabs(NSMaxY(p.frame) - 900) < 1, "filled: the content's size, the top left kept");

        const char *dir = getenv("DM_CONTROLS_CAPTURE");
        if (dir && *dir) capture(ctl_view(rows), dir);
    }
    printf("t_controls_mac: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
