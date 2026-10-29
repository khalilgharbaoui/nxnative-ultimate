// The C and Objective-C functions Launcher.swift and GameMenu.swift call (CloudSaves.h, DmGameMenu.h, save_sync.h's report before Play, save_archive.h for Save data).
// project.yml points SWIFT_OBJC_BRIDGING_HEADER here; save_archive.h is in the host's folder, which the iOS project's header search paths include (Gen/dm.xcconfig) and the
// Mac launcher passes to clang and swiftc.
#import "CloudSaves.h"
#import "DmGameMenu.h"
#include "save_sync.h"
#import "save_archive.h"
