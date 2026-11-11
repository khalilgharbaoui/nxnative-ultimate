// hdr_rects: a standalone check of "A fullscreen HDR layer shows rectangles of older frames" (docs/reference/rendering.md), with no game: an RGB10A2 BT.2100 PQ layer,
// with or without CAEDRMetadata HDR10, a CAMetalDisplayLink at 60 Hz with frame latency 2, the drawable sized to the view in pixels, a "game" compute pass of a set GPU time
// each frame on the same Metal 4 queue, then a present pass that copies its texture into the drawable. The present hands the drawable over in Apple's order (waitForDrawable,
// commit, signalDrawable, present: while the GPU still runs the game pass) or after the present pass completed, without signalDrawable (the host's DM_PRESENT_AFTER_GPU).
// The picture: bright bars sweeping right and a band sweeping down; rectangles of an older frame show as bar or band pieces out of line. Watch it in fullscreen on the built-in
// screen with nothing over the window.
// Modes: metadata 0 (none), 1 (0..1000 nits) or 2 (0..100 x the screen's headroom, which Core Animation passes through); after 0 or 1; load 0..3 (0, 6, 12, 18 ms of game GPU).
// Top-left squares: metadata, after-GPU, load (brighter = on, more). Keys: m metadata, o present order, l load, f fullscreen, q quit. `script` runs six phases of
// `phase=<s>` seconds (default 30) and quits, the phase number shown as white blocks at the top left: 1 metadata 1000, Apple's order, 12 ms; 2 none, Apple's, 12 ms; 3 metadata
// 1000, after the GPU, 12 ms; 4 none, Apple's, 18 ms; 5 metadata within the headroom, Apple's, 12 ms; 6 as 1. Each line it prints: frames, GPU times, frames shown more than
// 4 ms after their target, the window mode and the headroom.
// Needs macOS 26 or later (Metal 4). Build: clang++ -fobjc-arc -O1 -std=c++17 dm/gfx/tools/hdr_rects.mm -o hdr_rects -framework Cocoa -framework Metal -framework QuartzCore
// Run:   ./hdr_rects [script] [phase=<s>] [meta=0|1|2] [after=0|1] [load=0..3] [secs=<n>] [window]
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <atomic>
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>

static const char *kSrc = R"(
#include <metal_stdlib>
using namespace metal;
struct U { float t; uint iters; uint w; uint h; uint meta; uint after; uint load; uint pad; };
static float pq(float nits) { float y = pow(max(nits, 0.0) / 10000.0, 0.1593017578125);
    return pow((0.8359375 + 18.8515625 * y) / (1.0 + 18.6875 * y), 78.84375); }
kernel void game(texture2d<float, access::write> o [[texture(0)]], constant U &u [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= u.w || g.y >= u.h) return;
    float x = float(g.x) / float(u.w), y = float(g.y) / float(u.h), acc = x + y;
    for (uint i = 0; i < u.iters; i++) acc = fract(acc * 1.000173 + 0.3719);   // the load: a loop-carried chain the compiler cannot drop
    float bars = fract(x * 8.0 - u.t * 0.5) < 0.5 ? 1.0 : 0.0, band = fract(y * 3.0 + u.t * 0.4) < 0.12 ? 1.0 : 0.0;
    float nits = 40.0 + 260.0 * bars;
    if (band > 0.0) nits = bars > 0.0 ? 1000.0 : 150.0;
    if (u.pad == 0 && y < 0.05 && x < 0.15) { uint k = uint(x / 0.05); float on = k == 0 ? float(u.meta > 0) : k == 1 ? float(u.after) : float(u.load) / 3.0; nits = 3.0 + 500.0 * on; }
    if (u.pad > 0 && y < 0.08) { nits = 3.0; float c = x / 0.06; uint k = uint(c); if (k < u.pad && fract(c) < 0.7 && y > 0.015) nits = 300.0; }   // the phase: that many white blocks
    float v = pq(nits) + acc * 1e-9;
    o.write(float4(v, v, v, 1.0), g);
}
vertex float4 vs(uint id [[vertex_id]]) { float2 p = float2(float((id << 1) & 2), float(id & 2)); return float4(p * 2.0 - 1.0, 0.0, 1.0); }
fragment float4 fs(float4 pos [[position]], texture2d<float> t [[texture(0)]]) { return t.read(uint2(pos.xy)); }
)";

struct U { float t; uint32_t iters, w, h, meta, after, load, pad; };
static id<MTLDevice> dev; static id<MTL4CommandQueue> q; static CAMetalLayer *L; static CAMetalDisplayLink *link_;
static id<MTLComputePipelineState> cps; static id<MTLRenderPipelineState> rps; static id<MTLResidencySet> rs;
static id<MTL4CommandAllocator> ga[3], pa[3]; static id<MTL4CommandBuffer> gcb[3], pcb[3]; static id<MTL4ArgumentTable> ct[3], ft[3]; static id<MTLBuffer> ub[3];
static id<MTLTexture> gt; static dispatch_semaphore_t sem;
static std::atomic<int> meta{1}, after{0}, load{2}; static const double loadms[4] = {0, 6, 12, 18};   // set on the main thread, read on the link's
static std::atomic<double> iters{3000}; static uint64_t fn; static double t0; static NSScreen *g_scr;   // g_scr: the screen the window is on
static os_unfair_lock g_stat_lock = OS_UNFAIR_LOCK_INIT; static double gsum, psum; static int gn;   // the feedback handlers' sums, under the lock (they may run on several threads)
static std::atomic<int> late_frames{0};

static void apply_meta(void) {
    NSScreen *sc = g_scr ?: NSScreen.mainScreen;
    float mx = meta == 2 ? 100.0f * (float)sc.maximumExtendedDynamicRangeColorComponentValue : 1000.0f;
    L.EDRMetadata = meta ? [CAEDRMetadata HDR10MetadataWithMinLuminance:0 maxLuminance:mx opticalOutputScale:100] : nil;
}
static std::atomic<int> phase{0};
static void say(void) { printf("%.1f s: phase %d: metadata %s, present %s, game load %.0f ms\n", CACurrentMediaTime() - t0, phase.load(), meta == 2 ? "on, within the headroom" : meta ? "on (1000 nits)" : "off", after ? "after the GPU, no signalDrawable" : "Apple's order", loadms[load]); }

@interface Del : NSObject <CAMetalDisplayLinkDelegate> @end
@implementation Del
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)up {
    id<CAMetalDrawable> dr = up.drawable; if (!dr) return;
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    int i = (int)(fn % 3); fn++;
    NSUInteger w = dr.texture.width, h = dr.texture.height;
    if (!gt || gt.width != w || gt.height != h) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:w height:h mipmapped:NO];
        d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        // Metal 4 keeps no encoded resource alive: wait until no frame in flight still reads the old texture (all three slots free), then give the slot back
        for (int k = 0; k < 2; k++) dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        if (gt) [rs removeAllocation:gt];
        gt = [dev newTextureWithDescriptor:d]; [rs addAllocation:gt]; [rs commit];
        for (int k = 0; k < 2; k++) dispatch_semaphore_signal(sem);
    }
    [ga[i] reset]; [pa[i] reset];
    U *u = (U *)ub[i].contents;
    double ms = loadms[load];
    *u = (U){(float)(CACurrentMediaTime() - t0), ms > 0 ? (uint32_t)iters.load() : 0, (uint32_t)w, (uint32_t)h, (uint32_t)meta.load(), (uint32_t)after.load(), (uint32_t)load.load(), (uint32_t)phase.load()};
    // The game pass
    [gcb[i] beginCommandBufferWithAllocator:ga[i]];
    id<MTL4ComputeCommandEncoder> ce = [gcb[i] computeCommandEncoder];
    [ce barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [ce setComputePipelineState:cps]; [ct[i] setTexture:gt.gpuResourceID atIndex:0]; [ct[i] setAddress:ub[i].gpuAddress atIndex:0]; [ce setArgumentTable:ct[i]];
    [ce dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)]; [ce endEncoding]; [gcb[i] endCommandBuffer];
    MTL4CommitOptions *go = [MTL4CommitOptions new];
    [go addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
        double g = (f.GPUEndTime - f.GPUStartTime) * 1000.0;
        if (ms > 0 && g > 0.3) { double it = iters.load() * fmin(fmax(0.8 + 0.2 * ms / g, 0.5), 2.0); iters.store(it < 10 ? 10 : it > 2e6 ? 2e6 : it); }   // towards the set GPU time
        os_unfair_lock_lock(&g_stat_lock); gsum += g; gn++; os_unfair_lock_unlock(&g_stat_lock);
    }];
    id<MTL4CommandBuffer> gb[] = {gcb[i]};
    [q commit:gb count:1 options:go];
    // The present pass: waits on the GPU for the game pass (the barrier), as nxnative's waits for the game's frame
    [q waitForDrawable:dr];
    [pcb[i] beginCommandBufferWithAllocator:pa[i]];
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = dr.texture; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> re = [pcb[i] renderCommandEncoderWithDescriptor:rp];
    [re barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [re setRenderPipelineState:rps]; [ft[i] setTexture:gt.gpuResourceID atIndex:0]; [re setArgumentTable:ft[i] atStages:MTLRenderStageFragment];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding]; [pcb[i] endCommandBuffer];
    int late = after; double target = up.targetPresentationTimestamp;
    std::atomic<int> *need = late ? new std::atomic<int>(2) : nullptr;
    [dr addPresentedHandler:^(id<MTLDrawable> d) { if (d.presentedTime > target + 0.004) late_frames++; }];
    MTL4CommitOptions *po = [MTL4CommitOptions new];
    [po addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
        os_unfair_lock_lock(&g_stat_lock); psum += (f.GPUEndTime - f.GPUStartTime) * 1000.0; os_unfair_lock_unlock(&g_stat_lock);
        if (need && need->fetch_sub(1) == 1) { delete need; [dr present]; }
        dispatch_semaphore_signal(sem);
    }];
    id<MTL4CommandBuffer> pb[] = {pcb[i]};
    [q commit:pb count:1 options:po];
    if (!late) { [q signalDrawable:dr]; [dr present]; }
    else if (need->fetch_sub(1) == 1) { delete need; [dr present]; }
}
@end

@interface V : NSView @end
@implementation V
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (CALayer *)makeBackingLayer { return L; }
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; CGFloat k = self.window.backingScaleFactor ?: 2; L.contentsScale = k; L.drawableSize = CGSizeMake(s.width * k, s.height * k); }
- (void)viewDidChangeBackingProperties { [self setFrameSize:self.frame.size]; }
- (void)keyDown:(NSEvent *)e {
    unichar c = e.charactersIgnoringModifiers.length ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if (c == 'm') { meta = meta ? 0 : 1; apply_meta(); say(); }
    else if (c == 'o') { after = after ? 0 : 1; say(); }
    else if (c == 'l') { load = (load + 1) % 4; say(); }
    else if (c == 'f') [self.window toggleFullScreen:nil];
    else if (c == 'q') [NSApp terminate:nil];
}
@end

int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    int secs = 0, window = 0, script = 0, phase_s = 30;
    for (int a = 1; a < argc; a++) { const char *s = argv[a];
        if (!strncmp(s, "meta=", 5)) meta = atoi(s + 5); else if (!strncmp(s, "after=", 6)) after = atoi(s + 6);
        else if (!strncmp(s, "load=", 5)) load = atoi(s + 5) & 3; else if (!strncmp(s, "secs=", 5)) secs = atoi(s + 5); else if (!strcmp(s, "window")) window = 1;
        else if (!strcmp(s, "script")) script = 1; else if (!strncmp(s, "phase=", 6)) phase_s = atoi(s + 6); }
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    dev = MTLCreateSystemDefaultDevice(); q = [dev newMTL4CommandQueue]; sem = dispatch_semaphore_create(3);
    NSError *err = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:@(kSrc) options:nil error:&err];
    if (!lib) { fprintf(stderr, "shader: %s\n", err.localizedDescription.UTF8String); return 1; }
    cps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"game"] error:&err];
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new]; rd.vertexFunction = [lib newFunctionWithName:@"vs"]; rd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGB10A2Unorm; rps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    if (!cps || !rps) { fprintf(stderr, "pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }
    MTLResidencySetDescriptor *rsd = [MTLResidencySetDescriptor new]; rs = [dev newResidencySetWithDescriptor:rsd error:&err];
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxTextureBindCount = 1; ad.maxBufferBindCount = 1;
    for (int i = 0; i < 3; i++) { ga[i] = [dev newCommandAllocator]; pa[i] = [dev newCommandAllocator]; gcb[i] = [dev newCommandBuffer]; pcb[i] = [dev newCommandBuffer];
        ct[i] = [dev newArgumentTableWithDescriptor:ad error:&err]; ft[i] = [dev newArgumentTableWithDescriptor:ad error:&err];
        ub[i] = [dev newBufferWithLength:sizeof(U) options:MTLResourceStorageModeShared]; [rs addAllocation:ub[i]]; }
    [rs commit]; [q addResidencySet:rs];
    L = [CAMetalLayer layer]; L.device = dev; L.pixelFormat = MTLPixelFormatRGB10A2Unorm; L.framebufferOnly = YES;
    L.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ); L.wantsExtendedDynamicRangeContent = YES;
    [q addResidencySet:L.residencySet];
    NSScreen *scr = nil; for (NSScreen *s in NSScreen.screens) if (CGDisplayIsBuiltin([s.deviceDescription[@"NSScreenNumber"] unsignedIntValue])) scr = s;
    if (!scr) scr = NSScreen.mainScreen;
    g_scr = scr; apply_meta();   // after the screen is known: meta=2 reads its headroom
    NSRect vf = scr.visibleFrame;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(vf.origin.x + 60, vf.origin.y + 60, 960, 600) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskClosable
                                                  backing:NSBackingStoreBuffered defer:NO screen:scr];
    win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary; win.title = @"hdr_rects";
    V *v = [[V alloc] initWithFrame:NSMakeRect(0, 0, 960, 600)]; v.wantsLayer = YES; win.contentView = v; [v setFrameSize:v.frame.size];
    [win makeKeyAndOrderFront:nil]; [win makeFirstResponder:v]; [NSApp activateIgnoringOtherApps:YES];
    static Del *del; del = [Del new];   // the link's delegate is weak: kept alive here
    link_ = [[CAMetalDisplayLink alloc] initWithMetalLayer:L]; link_.delegate = del; link_.preferredFrameLatency = 2; link_.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    NSThread *lt = [[NSThread alloc] initWithBlock:^{   // the link on its own thread, as nxnative's: its frame-slot wait never blocks the main thread
        [link_ addToRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
        for (;;) @autoreleasepool { [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture]; }
    }];
    // script: a fixed timeline, phase_s seconds each, the phase number on screen; then quits. Phase 1 is set before the link starts, so no frame shows the defaults
    static const int ph[][3] = {{1, 0, 2}, {0, 0, 2}, {1, 1, 2}, {0, 0, 3}, {2, 0, 2}, {1, 0, 2}};   // {metadata, after-GPU, load}
    const int nph = sizeof ph / sizeof ph[0];
    if (script) { phase = 1; meta = ph[0][0]; after = ph[0][1]; load = ph[0][2]; apply_meta(); }
    lt.qualityOfService = NSQualityOfServiceUserInteractive; [lt start];
    t0 = CACurrentMediaTime(); say();
    if (script) [NSTimer scheduledTimerWithTimeInterval:phase_s repeats:YES block:^(NSTimer *tm) {
        if (phase >= nph) { [NSApp terminate:nil]; return; }
        int i = phase.load(); meta = ph[i][0]; after = ph[i][1]; load = ph[i][2]; phase = i + 1; apply_meta(); say();
    }];
    if (!window) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [win toggleFullScreen:nil]; [NSCursor hide]; });
    [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *tm) {
        os_unfair_lock_lock(&g_stat_lock); int n = gn; double g = gsum, p = psum; gn = 0; gsum = psum = 0; os_unfair_lock_unlock(&g_stat_lock); int lf = late_frames.exchange(0);
        printf("%5.1f s: %d frames/2 s, game GPU %.1f ms, present GPU %.2f ms, late %d, %s, headroom %.2f\n", CACurrentMediaTime() - t0, n, n ? g / n : 0, n ? p / n : 0, lf,
               win.styleMask & NSWindowStyleMaskFullScreen ? "fullscreen" : "window", win.screen.maximumExtendedDynamicRangeColorComponentValue);
        if (secs && CACurrentMediaTime() - t0 > secs) [NSApp terminate:nil];
    }];
    [NSApp run];
} return 0; }
