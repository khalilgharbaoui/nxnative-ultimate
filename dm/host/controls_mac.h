// The Controls panel (front_mac.m's DmControlsPanel, Window > Show Controls): every Switch control and its key, grouped, read from the key map that on_key reads
// (keymap_mac.h), then the touchscreen, the menu bar's shortcuts read from the menu itself, and a line on controllers. Built here alone, so tests/t_controls_mac.m
// checks the rows against the map and draws the panel without a game.
// The panel is a dark see-through utility panel (HUD style) that never becomes key: a click or a drag on it leaves the keyboard and the controllers with the game.
// A panel and not a view inside the game window, so that it can sit beside the picture instead of over it, and the player can drag it anywhere.
#pragma once
#import <Cocoa/Cocoa.h>
#include <string.h>
#include "keymap_mac.h"

// A control's column is at most this wide (points): a longer name (the Quit item carries the game's: "Quit The Legend of Zelda: Ocarina of Time") is cut, its whole
// text in the tooltip, so the panel stays narrow
#define CTL_CONTROL_W 160
#define CTL_TOUCH_GROUP @"Touchscreen"
#define CTL_MENU_GROUP @"Window shortcuts"
// The line on controllers (pad_apple.h dm_pad_face: a Nintendo pad's face buttons by their labels, any other pad's by position, as the Switch has them)
#define CTL_PADS @"Controllers: a Nintendo pad by its labels, any other by position (right A, bottom B, top X, left Y)."

// A menu item's shortcut as the menu shows it: ⌃⌥⇧⌘ and the key ("⌃⌘F"); an upper-case key equivalent implies Shift. nil without one
static NSString *ctl_shortcut(NSMenuItem *it) {
    NSString *k = it.keyEquivalent;
    if (!k.length) return nil;
    NSEventModifierFlags m = it.keyEquivalentModifierMask;
    if (![k isEqualToString:k.lowercaseString]) m |= NSEventModifierFlagShift;
    NSMutableString *s = [NSMutableString string];
    if (m & NSEventModifierFlagFunction) [s appendString:@"fn "];
    if (m & NSEventModifierFlagControl) [s appendString:@"⌃"];
    if (m & NSEventModifierFlagOption) [s appendString:@"⌥"];
    if (m & NSEventModifierFlagShift) [s appendString:@"⇧"];
    if (m & NSEventModifierFlagCommand) [s appendString:@"⌘"];
    NSDictionary<NSString *, NSString *> *named = @{@"\r": @"↩", @"\t": @"⇥", @" ": @"Space", @"\x1b": @"⎋"};
    [s appendString:named[k] ?: k.uppercaseString];
    return s;
}

// Every shown item of the menu and its submenus that has a shortcut, in menu order: (title, shortcut)
static void ctl_menu_shortcuts(NSMenu *menu, NSMutableArray<NSArray<NSString *> *> *out) {
    for (NSMenuItem *it in menu.itemArray) {
        if (it.hidden || it.alternate) continue;
        NSString *s = ctl_shortcut(it);
        if (s && it.title.length) [out addObject:@[it.title, s]];
        if (it.submenu) ctl_menu_shortcuts(it.submenu, out);
    }
}

// The panel's rows, top to bottom: a heading is a row of one string (a group's name), a control a row of two (the control, its keys). The keys of one control in
// one group share its row, in the map's order (W A S D); a row of Shift keys says so once ("Shift + ↑ ← ↓ →")
static NSArray<NSArray<NSString *> *> *ctl_rows(NSMenu *menu) {
    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
    for (int g = 0; g < KM_GROUPS; g++) {
        [rows addObject:@[@(km_group_names[g])]];
        for (size_t i = 0; i < KM_KEYS; i++) {
            const km_key *k = &km_keys[i];
            int first = k->group == g;
            for (size_t j = 0; first && j < i; j++) first = !(km_keys[j].group == g && !strcmp(km_keys[j].control, k->control));
            if (!first) continue;
            NSMutableArray<NSString *> *keys = [NSMutableArray array];
            int shift = 0;
            for (size_t j = i; j < KM_KEYS; j++) if (km_keys[j].group == g && !strcmp(km_keys[j].control, k->control)) { [keys addObject:@(km_keys[j].key)]; shift |= km_keys[j].shift; }
            NSString *text = [keys componentsJoinedByString:@" "];
            [rows addObject:@[@(k->control), shift ? [@"Shift + " stringByAppendingString:text] : text]];
        }
    }
    [rows addObject:@[CTL_TOUCH_GROUP]];
    [rows addObject:@[@"Touch and drag", @"Left mouse button"]];   // DmGameView: a click or a drag on the picture is finger 0
    NSMutableArray<NSArray<NSString *> *> *shortcuts = [NSMutableArray array];
    if (menu) ctl_menu_shortcuts(menu, shortcuts);
    if (shortcuts.count) { [rows addObject:@[CTL_MENU_GROUP]]; [rows addObjectsFromArray:shortcuts]; }
    return rows;
}

static NSTextField *ctl_label(NSString *text, CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *t = [NSTextField labelWithString:text];   // a label: not editable, not selectable, never the first responder
    t.font = [NSFont systemFontOfSize:size weight:w]; t.textColor = c;
    return t;
}

// The panel's view: the rows as a two-column grid (a heading spans both), then the controllers line, wrapped to the grid's width. Sized by its constraints:
// fittingSize is the panel's content size
static NSView *ctl_view(NSArray<NSArray<NSString *> *> *rows) {
    NSGridView *grid = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
    grid.rowSpacing = 1; grid.columnSpacing = 16; grid.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSArray<NSString *> *r in rows) {
        if (r.count == 1) {
            NSGridRow *h = [grid addRowWithViews:@[ctl_label(r[0], 10, NSFontWeightSemibold, NSColor.secondaryLabelColor), NSGridCell.emptyContentView]];
            [h mergeCellsInRange:NSMakeRange(0, 2)];
            if (grid.numberOfRows > 1) h.topPadding = 6;
        } else {
            NSTextField *control = ctl_label(r[0], 11, NSFontWeightRegular, NSColor.labelColor);
            control.lineBreakMode = NSLineBreakByTruncatingTail; control.toolTip = r[0];
            [control setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
            [control.widthAnchor constraintLessThanOrEqualToConstant:CTL_CONTROL_W].active = YES;
            [grid addRowWithViews:@[control, ctl_label(r[1], 11, NSFontWeightSemibold, NSColor.labelColor)]];
        }
    }
    NSTextField *pads = [NSTextField wrappingLabelWithString:CTL_PADS];
    pads.font = [NSFont systemFontOfSize:10]; pads.textColor = NSColor.secondaryLabelColor; pads.selectable = NO;
    pads.translatesAutoresizingMaskIntoConstraints = NO;
    pads.preferredMaxLayoutWidth = grid.fittingSize.width;
    NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
    [v addSubview:grid]; [v addSubview:pads];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:v.topAnchor constant:8], [grid.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:12],
        [grid.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-12],
        [pads.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:10], [pads.leadingAnchor constraintEqualToAnchor:grid.leadingAnchor],
        [pads.trailingAnchor constraintEqualToAnchor:grid.trailingAnchor], [pads.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-10],
    ]];
    return v;
}

// The panel never becomes key or main: the game window keeps the keyboard and the controllers whatever is clicked here (its close button and a drag work without)
@interface DmControlsNSPanel : NSPanel @end
@implementation DmControlsNSPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// The panel, hidden: floating over the game window (fullscreen too), hidden while another app is active, moved by its title bar or its background
static NSPanel *ctl_panel(void) {
    NSPanel *p = [[DmControlsNSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 240, 400)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskHUDWindow | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    p.title = @"Controls";
    p.releasedWhenClosed = NO;      // the close button only hides it (the controller's windowShouldClose)
    p.floatingPanel = YES;
    p.becomesKeyOnlyIfNeeded = YES;
    p.hidesOnDeactivate = YES;
    p.movableByWindowBackground = YES;
    p.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace;   // shown on the Space it is asked on, the fullscreen game's too
    return p;
}

// The panel's content becomes the rows' view, sized to fit, its top left corner kept where it was
static void ctl_panel_fill(NSPanel *p, NSArray<NSArray<NSString *> *> *rows) {
    NSRect was = p.frame;
    NSView *v = ctl_view(rows);
    p.contentView = v;
    [p setContentSize:v.fittingSize];
    [p setFrameTopLeftPoint:NSMakePoint(NSMinX(was), NSMaxY(was))];
}
