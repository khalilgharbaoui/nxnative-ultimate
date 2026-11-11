// edr_probe: how macOS maps a PQ (BT.2100) CAMetalLayer with HDR10 metadata into EDR, measured by an extended-range screen capture.
// One window on the built-in screen (or the main one without it): an SDR white view (reads EDR 1.0), a float extended-linear layer at known EDR values (checks the capture), and an
// RGB10A2 PQ layer with grey patches at known nits. For each metadata setting it presents, waits, captures the screen in extended linear Display P3
// (ScreenCaptureKit, HDR local display) and prints the captured value at each patch. Needs macOS 15 or later (an HDR screen capture) and the Screen Recording permission. Build: clang -fobjc-arc -O1 dm/gfx/tools/edr_probe.m -o edr_probe -framework Cocoa
// -framework Metal -framework QuartzCore -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <math.h>

static const double kNits[] = {25, 50, 100, 150, 203, 300, 400, 600, 1000, 1600, 4000};
#define NP (int)(sizeof kNits / sizeof kNits[0])
static const double kEdr[] = {0.5, 1.0, 2.0, 4.0};
#define NE 4
#define PW 100   // patch width in points
#define PH 120   // patch height in points

static double pq_encode(double nits) {   // SMPTE ST 2084 inverse EOTF: nits -> code value 0..1
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128, c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32;
    double y = pow(fmax(nits, 0) / 10000.0, m1);
    return pow((c1 + c2 * y) / (1 + c3 * y), m2);
}

static id<MTLDevice> g_dev; static id<MTLCommandQueue> g_q;
static CAMetalLayer *g_pq, *g_fl; static NSView *g_view; static NSWindow *g_win;

static int fill_and_present(CAMetalLayer *layer, int pq) {   // 0 when the layer gave no drawable   // draws the patches into a CPU texture and blits it into a drawable
    CGSize sz = layer.drawableSize; NSUInteger w = (NSUInteger)sz.width, h = (NSUInteger)sz.height;
    int n = pq ? NP : NE; double scale = layer.contentsScale;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:layer.pixelFormat width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d];
    if (pq) {
        uint32_t *px = calloc(w * h, 4);
        for (NSUInteger y = 0; y < h; y++) for (NSUInteger x = 0; x < w; x++) {
            int i = (int)(x / (PW * scale)); double nits = i < n ? kNits[i] : 0;
            uint32_t c = (uint32_t)lround(pq_encode(nits) * 1023.0);
            px[y * w + x] = c | c << 10 | c << 20 | 3u << 30;
        }
        [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:w * 4]; free(px);
    } else {
        __fp16 *px = calloc(w * h * 4, 2);
        for (NSUInteger y = 0; y < h; y++) for (NSUInteger x = 0; x < w; x++) {
            int i = (int)(x / (PW * scale)); double v = i < n ? kEdr[i] : 0;
            __fp16 *p = px + (y * w + x) * 4; p[0] = p[1] = p[2] = (__fp16)v; p[3] = 1;
        }
        [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:w * 8]; free(px);
    }
    id<CAMetalDrawable> dr = [layer nextDrawable];
    if (!dr) { fprintf(stderr, "edr_probe: no drawable (the display asleep?)\n"); return 0; }
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t toTexture:dr.texture]; [b endEncoding]; [cb presentDrawable:dr]; [cb commit]; [cb waitUntilCompleted];
    return 1;
}

typedef struct { const char *name; int meta; float lo, hi, scale; } config_t;
static const config_t kConfigs[] = {   // hi < 0: |hi| times 100 nits times the screen's current headroom (measured when the config runs)
    {"no EDR metadata", 0, 0, 0, 0},
    {"hdr10 0..710 (OoT's declared range), opticalOutputScale 203", 1, 0, 710, 203},
    {"hdr10 0..710, opticalOutputScale 100", 1, 0, 710, 100},
    {"hdr10 0..(100 x headroom), opticalOutputScale 100", 1, 0, -1, 100},
    {"hdr10 0..(203 x headroom), opticalOutputScale 203", 1, 0, -2.03f, 203},
};
#define NC (int)(sizeof kConfigs / sizeof kConfigs[0])


static float *g_bm; static size_t g_W, g_H;
static double at(double cx, double cy) {   // mean of the green channel over 9x9 pixels at a screen-pixel position
    double acc = 0; int n = 0;
    for (int dy = -4; dy <= 4; dy++) for (int dx = -4; dx <= 4; dx++) { double fx = cx + dx, fy = cy + dy; if (fx < 0 || fy < 0) continue; size_t X = (size_t)fx, Y = (size_t)fy; if (X < g_W && Y < g_H) { acc += g_bm[(Y * g_W + X) * 4 + 1]; n++; } }
    return n ? acc / n : NAN;
}
static void sample_image(CGImageRef img, const char *tag) {
    CFStringRef csn = CGColorSpaceCopyName(CGImageGetColorSpace(img)); char csb[128] = "(unnamed)";
    if (csn) { if (!CFStringGetCString(csn, csb, sizeof csb, kCFStringEncodingUTF8)) strcpy(csb, "(unreadable)"); CFRelease(csn); }
    printf("%s\tcaptured %zux%zu, %zu bits per component, colour space %s, bitmap info 0x%x\n", tag, CGImageGetWidth(img), CGImageGetHeight(img), CGImageGetBitsPerComponent(img),
           csb, (unsigned)CGImageGetBitmapInfo(img));
    g_W = CGImageGetWidth(img); g_H = CGImageGetHeight(img); free(g_bm); g_bm = calloc(g_W * g_H * 4, sizeof(float));
    CGColorSpaceRef lin = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
    CGContextRef ctx = CGBitmapContextCreate(g_bm, g_W, g_H, 32, g_W * 16, lin, kCGImageAlphaPremultipliedLast | kCGBitmapFloatComponents | kCGBitmapByteOrder32Little);
    if (!ctx) { printf("%s\tno float bitmap for the capture: skipped\n", tag); CGColorSpaceRelease(lin); return; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, g_W, g_H), img); CGContextRelease(ctx); CGColorSpaceRelease(lin);
    NSScreen *sc = g_win.screen; NSRect sf = sc.frame; double sx = g_W / sf.size.width, sy = g_H / sf.size.height;
    printf("%s\theadroom now %.2f, potential %.2f\n", tag, sc.maximumExtendedDynamicRangeColorComponentValue, sc.maximumPotentialExtendedDynamicRangeColorComponentValue);
    double (^pos)(CGRect, int, int) = ^double(CGRect lr, int i, int wantY) {   // a patch centre in bitmap pixels (bitmap rows go top down)
        NSRect wf = [g_win convertRectToScreen:[g_view convertRect:NSRectFromCGRect(lr) toView:nil]];
        return wantY ? (sf.size.height - (wf.origin.y - sf.origin.y + PH / 2.0)) * sy : (wf.origin.x - sf.origin.x + PW * i + PW / 2.0) * sx;
    };
    CGRect wr = CGRectMake(0, g_view.bounds.size.height - PH, PW, PH);
    printf("%s\tSDR white view\tEDR %.4f\n", tag, at(pos(wr, 0, 0), pos(wr, 0, 1)));
    for (int i = 0; i < NE; i++) printf("%s\tfloat layer %.2f\tEDR %.4f\n", tag, kEdr[i], at(pos(g_fl.frame, i, 0), pos(g_fl.frame, i, 1)));
    for (int i = 0; i < NP; i++) { double v = at(pos(g_pq.frame, i, 0), pos(g_pq.frame, i, 1)); printf("%s\tPQ %6.0f nits\tEDR %.4f\t(nits per EDR 1.0: %.1f)\n", tag, kNits[i], v, kNits[i] / v); }
}

static void run_config(int c, SCDisplay *display) {
    if (c >= NC) { [NSApp terminate:nil]; return; }
    const config_t *k = &kConfigs[c]; printf("config %d: %s\n", c, k->name);
    float hi = k->hi < 0 ? (float)(-k->hi * 100.0 * g_win.screen.maximumExtendedDynamicRangeColorComponentValue) : k->hi;
    if (k->meta) printf("config %d: metadata max %.0f nits\n", c, hi);
    g_pq.EDRMetadata = k->meta ? [CAEDRMetadata HDR10MetadataWithMinLuminance:k->lo maxLuminance:hi opticalOutputScale:k->scale] : nil;
    fill_and_present(g_pq, 1); fill_and_present(g_fl, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        int ok = fill_and_present(g_pq, 1); ok &= fill_and_present(g_fl, 0);
        if (!ok) { printf("config %d: skipped (no drawable)\n", c); run_config(c + 1, display); return; }
        SCContentFilter *f = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        SCStreamConfiguration *cfg = [SCStreamConfiguration new];
        cfg.width = (size_t)(display.width * g_win.screen.backingScaleFactor); cfg.height = (size_t)(display.height * g_win.screen.backingScaleFactor);
        cfg.pixelFormat = kCVPixelFormatType_64RGBAHalf; cfg.colorSpaceName = kCGColorSpaceExtendedLinearDisplayP3;
        cfg.captureDynamicRange = SCCaptureDynamicRangeHDRLocalDisplay; cfg.showsCursor = NO;
        [SCScreenshotManager captureImageWithFilter:f configuration:cfg completionHandler:^(CGImageRef img, NSError *e) {
            if (img) CGImageRetain(img);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (e || !img) printf("%s\tcapture failed: %s\n", k->name, e ? e.description.UTF8String : "no image and no error");
                else { sample_image(img, k->name); CGImageRelease(img); }
                run_config(c + 1, display);
            });
        }];
    });
}

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); printf("start\n");
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    g_dev = MTLCreateSystemDefaultDevice(); g_q = [g_dev newCommandQueue];
    NSScreen *builtin = nil;
    for (NSScreen *s in NSScreen.screens) if (CGDisplayIsBuiltin([s.deviceDescription[@"NSScreenNumber"] unsignedIntValue])) builtin = s;
    if (!builtin) builtin = NSScreen.mainScreen;   // no built-in screen (an external HDR screen, a closed lid): the main one
    double W = PW * NP + 40, H = PH * 3 + 40;
    NSRect vf = builtin.visibleFrame;
    g_win = [[NSWindow alloc] initWithContentRect:NSMakeRect(vf.origin.x + 20, vf.origin.y + vf.size.height - H - 60, W, H) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO screen:builtin];
    g_win.title = @"edrprobe"; g_view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, H)]; g_view.wantsLayer = YES;
    g_view.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    CALayer *white = [CALayer layer]; white.frame = CGRectMake(0, H - PH, PW, PH);   // SDR white, top left
    white.backgroundColor = CGColorCreateSRGB(1, 1, 1, 1); [g_view.layer addSublayer:white];
    double cs = builtin.backingScaleFactor;
    g_fl = [CAMetalLayer layer]; g_fl.device = g_dev; g_fl.pixelFormat = MTLPixelFormatRGBA16Float; g_fl.framebufferOnly = NO;
    g_fl.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3); g_fl.wantsExtendedDynamicRangeContent = YES;
    g_fl.frame = CGRectMake(0, H - 2 * PH - 10, PW * NE, PH); g_fl.contentsScale = cs; g_fl.drawableSize = CGSizeMake(PW * NE * cs, PH * cs);
    g_pq = [CAMetalLayer layer]; g_pq.device = g_dev; g_pq.pixelFormat = MTLPixelFormatRGB10A2Unorm; g_pq.framebufferOnly = NO;
    g_pq.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ); g_pq.wantsExtendedDynamicRangeContent = YES;
    g_pq.frame = CGRectMake(0, 10, PW * NP, PH); g_pq.contentsScale = cs; g_pq.drawableSize = CGSizeMake(PW * NP * cs, PH * cs);
    [g_view.layer addSublayer:g_fl]; [g_view.layer addSublayer:g_pq];
    g_win.contentView = g_view; [g_win makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    CGDirectDisplayID did = [builtin.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    printf("asking for shareable content\n");
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *e) {
        printf("shareable content: %lu displays, error %s\n", (unsigned long)content.displays.count, e ? e.description.UTF8String : "none");
        SCDisplay *display = nil; for (SCDisplay *d in content.displays) if (d.displayID == did) display = d;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!display) { fprintf(stderr, "no shareable built-in display: %s\n", e.description.UTF8String ?: "(no error; screen recording permission?)"); [NSApp terminate:nil]; return; }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ run_config(0, display); });
        });
    }];
    [NSApp run];
}
    return 0;
}
