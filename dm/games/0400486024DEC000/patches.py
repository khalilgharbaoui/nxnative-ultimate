# The Legend of Zelda: Ocarina of Time (0400486024DEC000): the rewriter's patches of this game's own code. dm/tools/patch_nso.py loads every profile's patches.py;
# MATCH_FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
from nso_asm import ADRP, B

# The game's frame ratio. Once a frame the function at main+0x6e6be0 (v131072, ModuleSystem::moduleCalc_ by the name of its job) divides its base rate (60.0, or 30.0 while
# bit 0 of [x21+0x24f] is set) by the int frame rate at [x21+0x2c8] (fdiv s8,s1,s0 at +0xe4) and hands the result to the time object (main+0x3b4e300: ratio at +0x10, 1 / ratio
# at +0x14, ratio / 60 at +0x18, the step in seconds, round(60 / ratio) at +0x1c), which the game steps by; the frame's own time never enters it, so a frame that takes two
# vsyncs at rate 60 plays at half speed. The stub gives the ratio the host's step instead: step × base / 60, and counts the vsyncs stepped. Until the host has decided a step,
# and at fps_target 0, the division runs. s0 and x16 / x17 are free there (s0 is written again on every path before it is read; the function uses neither x16 nor x17); s1 keeps
# the base rate and x21 the framework.
# Why × base / 60 and not the step alone (PR #1996 read base 30 as a cutscene rate and took the step, twice the speed there): the ratio's unit is 1/60 s whatever the base
# (the time object's +0x18 is ratio × 1/60, the constant at main+0x3e4066c). Base 30 is the framework's half rate: bit 0 of its +0x24f is that mode and bit 1 flips each pass of
# its frame function (main+0x346c680); with both set the draw and the present return at once (main+0x2cb020, main+0x40cd20) while the calc tree runs (main+0x2cabd0). So it
# calcs twice a drawn frame, this function among them, and each calc takes half the frame's step: 30 / 30 = 1 twice a 30 fps frame on the console, step / 2 twice here. The
# vsyncs are counted once a drawn frame, at the calc that is drawn (bit 1 clear): counted at both, the host's game time read twice the real time in that mode.
# The branch targets are computed from the words emitted, so a word added to the stub cannot leave one pointing into its middle (dsi-hub's HookLink met that on an iPhone,
# a fault on the first frame, when a block was added between main's fixed offsets and their target).
# Lichii (a GPL emulator; only the fact was taken) found the division (its notes: main+0x6E6CC4, 60 / [x21+0x2C8])
def frame_step(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF, base = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state, ctx.base
    site = base + 0xe4
    fs_site(site, '2818201e')   # fdiv s8,s1,s0
    start = here()
    ORIG, COUNTED, n = 18, 13, [0]   # the original division is word 18 of the stub, the ratio starts at word 13 (both checked below); n counts the words emitted
    def put(w): emit(w); n[0] += 1
    def cbz_w17_orig(): return 0x34000000 | (((ORIG - n[0]) & 0x7FFFF) << 5) | 17   # from this word to word ORIG
    put(ADRP(16, here(), FS_STATE_OFF))
    put(0xb9400211)             # ldr w17,[x16]          target fps (0 = off)
    put(cbz_w17_orig())         # cbz w17,orig
    put(0xb9402211)             # ldr w17,[x16,#0x20]    step in vsyncs
    put(cbz_w17_orig())         # cbz w17,orig           not decided yet
    put(0x1e230220)             # ucvtf s0,w17
    put(0x39493eb0)             # ldrb w16,[x21,#0x24f]  the framework's half-rate bits
    put(0x37000000 | 1 << 19 | ((COUNTED - n[0]) & 0x3FFF) << 5 | 16)   # tbnz w16,#1,ratio: the calc of a half-rate frame that is not drawn; its vsyncs are counted at the drawn one
    put(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xf9401a10,   # ldr x16,[x16,#0x30]
              0x8b110210):  # add x16,x16,x17
        put(w)
    put(ADRP(17, here(), FS_STATE_OFF))
    put(0xf9001a30)             # str x16,[x17,#0x30]    vsyncs stepped
    assert n[0] == COUNTED, f'frame_step: the ratio starts at word {n[0]}, the tbnz goes to word {COUNTED}'
    for w in (0x1e210808,   # fmul s8,s0,s1          step × base rate
              0x52a84e10,   # mov w16,#0x42700000    60.0
              0x1e270200,   # fmov s0,w16
              0x1e201908):  # fdiv s8,s8,s0          / 60
        put(w)
    put(B(here(), site + 4))
    assert n[0] == ORIG, f'frame_step: the original division is word {n[0]}, the cbz branches go to word {ORIG}'
    emit(0x1e201828); emit(B(here(), site + 4))   # orig: fdiv s8,s1,s0; back
    fs_put(site, [B(site, start)], 'frame ratio: the host\'s step × base rate / 60 instead of base rate / the game\'s frame rate (state page target fps; 0 = the game\'s ratio)')
    dynamic_resolution(ctx)

# The game's dynamic resolution (game__gfx__DynamicResolutionParam: LoadThreshold, ReduceCounterMax, IncreaseCounterMax and a list of levels, each a ResolutionReduceScale and a
# Priority; on v131072 levels 0..9 at 0.75..0.333 of 2048x1152, 1536x864 to 683x384). Its update (main+0x805aa0) reads the frame's GPU load (about 0.2 ms a unit) into +0x8, subtracts
# its small model of the fixed costs and divides the rest by the square of the current scale: it takes the rest of the frame's cost to grow with the pixel count, as on the Switch 2
# its constants were tuned for. The level function (main+0x8065e0) adds that back times each level's scale squared and returns the best level under the threshold (+0x10, 83 = about
# 16.4 ms). On Apple GPUs this game's cost hardly depends on the resolution (mesh, compute and the upscaler's fixed 2048x1152 dominate): 683x384 cost 14.3 ms and 1536x864 14.7 ms on
# an M4 Pro, yet at 683x384 the extrapolation put 1536x864 at about 300 units against the 83 it allows, so the controller sat at its floor for good (game note, Dynamic resolution).
# The stub replaces the level function. With DM_DYNAMIC_RESOLUTION 0 (the default; state +0x40 0) it returns 0: full resolution. With 1 it climbs on what was measured at each
# level, with no model of how the cost grows: one level down when the load (+0x8) has been over the threshold for 8 calls in a row, and that level is marked as not fitting; one level
# up when the load fits and the level above was never measured, fitted when it was last measured, or was measured more than 600 calls (about 10 s) ago; else the current level
# (+0x174). Nothing is decided or recorded until a level has held 8 calls: the load is read a few frames late, so before that it may be the previous level's. The 8 calls over in a
# row keep a single slow frame, or the first frames at a new size (its render targets), from marking a level that fits (on the full library at level 1: one burst to 90 against loads
# of 77-80 at levels 2 and 1). The game's counters still pace the steps (down after ReduceCounterMax frames, up after IncreaseCounterMax); its level count (+0x1a0) is the floor.
# The memory is in the state page: +0x200 calls, +0x204 the last call's level, +0x208 calls at it, +0x20c calls over in a row, +0x210 the load measured at each level (16 floats),
# +0x250 the call it was measured at (0 = never). Run against a model of the update (a level moves after the stub asked 5 times up or 2 times down; the load two frames late): a load
# of 70 at every level climbs from the floor to full size in 9 steps, as does Ocarina's measured 72-80 with a spike every 37 frames and a burst after each change; a load that grows
# with the pixel count settles at the highest level that fits and tries the one above once per 600 calls; a scene that gets lighter climbs again, a heavier one steps down.
# The function is a leaf: x2..x11, x16, x17 and s0..s2 are free, w0 its only result (the original also stores its predicted cost at +0x18, which only it and the update's own
# decision read). The update's fingerprint is required too: +0x8 and +0x174 are its fields
drs_controller = (   # drs_stub.s, assembled with clang; x0 the controller, x16 the state page (the ADRP before it)
    0xb9404211, 0x35000071, 'DRS_OFF_B', 0xd65f03c0,                                                    # off (state +0x40 0): level 0 at the render scale (the block at the end)
    0xbd400800, 0xbd401001, 0xb9417402, 0xb941a003, 0x7100005f, 0x1a9fa042, 0x528001e9, 0x6b09005f,   # load, threshold, level (0..15), count
    0x1a89d042, 0xb9420204, 0x11000484, 0xb9020204, 0xb9420605, 0xb9420a06, 0x6b0200bf, 0x1a8617e6,   # calls + 1; calls at this level
    0xb9020602, 0xb9020a06, 0x35000046, 0xb9020e1f, 0x91084207, 0x91094208, 0x710020df, 0x5400040b,   # a new level: none over; under 8 calls: stay
    0x1e212000, 0x540001ad, 0xb9420e0b, 0x1100056b, 0xb9020e0b, 0x7100217f, 0x5400032b,               # over: under 8 in a row, stay
    0xbc2258e0, 0xb8225904, 0x51000469, 0x1100044a, 0x6b09015f, 0x1a89d140, 0xd65f03c0,               # 8 in a row: record it, down one (to the floor)
    0xb9020e1f, 0xbc2258e0, 0xb8225904, 0x34000182, 0x51000449, 0xb869590a, 0x340000ea, 0x4b0a008a,   # fits: record it; at 0 stay; the level above's record
    0x7109615f, 0x54000088, 0xbc6958e2, 0x1e212040, 0x540000aa, 0x2a0903e0, 0xd65f03c0,               # never, stale or fitting: up one
    0x2a1f03e0, 0xd65f03c0, 0x2a0203e0, 0xd65f03c0,                                                   # 0; or stay
    # off, level 0 at the host's render scale (state +0x10, DM_RENDER_SCALE): its scale (the list's first entry, [first + -8]; head +0x198, end +0x190) = the game's own (kept at
    # state +0x2a0 on the first call) x the render scale, at most 1.0, the native size of the output. 1.0, the default, writes the game's own back
    0xf940cc03, 0x91064004, 0xeb04007f, 0x54000260, 0xbd42a201, 0x1e202028, 0x54000061, 0xbc5f8061,   # first entry (none: level 0); the game's scale, kept once
    0xbd02a201, 0xbd401200, 0x1e202008, 0x5400016d, 0x1e200821, 0x1e2e1002, 0x1e227821,               # x the render scale (0 or less: as it is), at most 1.0
    0x1e2d1003, 0x1e230803, 0x1e222060, 0x1e2f1004, 0x1e240863, 0x1e21cc61,                           # above 1.333: 1.5 x 0.75 x the render scale (the 3840x2160 output, below)
    0xbc1f8061, 0x2a1f03e0, 0xd65f03c0)                                                               # level 0
drs_off_len = 24
drs_controller = tuple(0x14000000 | (len(drs_controller) - drs_off_len - 2) if w == 'DRS_OFF_B' else w for w in drs_controller)   # b to the off block, the last 22 words
def screen_shape(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    def patch_height(site, orig_hex, state_off, kind, why):
        fs_site(site, orig_hex)
        start = here()
        emit(int.from_bytes(bytes.fromhex(orig_hex), 'little'))
        emit(ADRP(16, here(), FS_STATE_OFF))
        emit(0xb9400210 | ((state_off // 4) << 10))   # ldr w16, [x16, #state_off]
        if kind == 'hi32_4_3':
            body = (0x340000b0,   # cbz w16, +20
                    0x531e7610,   # lsl w16, w16, #2
                    0x52800071,   # mov w17, #3
                    0x1ad10a10,   # udiv w16, w16, w17
                    0xb3607e08)   # bfi x8, x16, #32, #32
        elif kind == 'hi32':
            body = (0x34000050,   # cbz w16, +8
                    0xb3607e08)   # bfi x8, x16, #32, #32
        elif kind == 'w10':
            body = (0x34000050,   # cbz w16, +8
                    0x2a1003ea)   # mov w10, w16
        elif kind == 'f32_w8':
            body = (0x34000070,   # cbz w16, +12
                    0x1e230200,   # ucvtf s0, w16 (s0 overwritten at site+4)
                    0x1e260008)   # fmov w8, s0
        for w in body: emit(w)
        emit(B(here(), site + 4))
        fs_put(site, [B(site, start)], why)

    # All 1920x1080, 2560x1440, 1280x720, and 1080.0f height sites across InitializeGraphicsSystem, scene defaults, and display manager.
    sites = [
        ('graphics system init', 0x204, '08b4c0f2', 0x48, 'hi32_4_3', 'swapchain height = host oh * 4 / 3'),
        ('graphics system init', 0x3c0, '8886e8f2', 0x50, 'hi32',     'virtual screen height = host layout height'),
        ('scene app init',       0x168, '08b4c0f2', 0x48, 'hi32_4_3', 'scene app RT height (2560x1440 -> 2560 x oh*4/3)'),
        ('scene app init',       0x174, '0887c0f2', 0x48, 'hi32',     'scene app RT height (1920x1080 -> 1920 x oh)'),
        ('base scene defaults',  0x38c, '0887c0f2', 0x48, 'hi32',     'base scene full height (1920x1080 -> 1920 x oh)'),
        ('base scene defaults',  0x39c, '085ac0f2', 0x4c, 'hi32',     'base scene layout height (1280x720 -> 1280 x lh)'),
        ('display mgr defaults', 0x00c, '0a878052', 0x48, 'w10',      'display mgr table height (1080 -> oh)'),
        ('base res read',        0x114, 'e890a852', 0x48, 'f32_w8',   'base res reference height (1080.0f -> (float)oh)'),
        ('display target a',     0x044, '0887c0f2', 0x48, 'hi32',     'display target height a (1920x1080 -> 1920 x oh)'),
        ('display target b',     0x110, '0887c0f2', 0x48, 'hi32',     'display target height b (1920x1080 -> 1920 x oh)'),
        ('display target c',     0x130, '0887c0f2', 0x48, 'hi32',     'display target height c (1920x1080 -> 1920 x oh)'),
    ]
    for key, off, orig_hex, state_off, kind, why in sites:
        fn = ctx.others.get(key)
        if fn is not None: patch_height(fn + off, orig_hex, state_off, kind, why)

    # Layout2 ortho projection builder: scales 16:9 canvas height (>= 1000 wide, e.g. 1920x1080 or 1280x720) by state +0x5c (k = (16/9) / aspect) so UI widgets keep 1:1 pixel aspect.
    # At +0x208 (orig ldr q6, [sp, #0xa0]), x16/x17, v0..v3 and nzcv are free; stores updated {W, H'} back to [sp, #0xa0] for both ortho blocks (x19+0xbf0 and x19+0xca0).
    ortho_fn = ctx.others.get('layout ortho')
    if ortho_fn is not None:
        ortho_site = ortho_fn + 0x208
        fs_site(ortho_site, 'e62bc03d')   # ldr q6, [sp, #0xa0]
        start = here()
        emit(0x3dc02be6)
        emit(ADRP(16, here(), FS_STATE_OFF))
        for w in (0xb9404a11, 0x34000291, 0x52a88f51, 0x1e270222, 0x5e0404c0, 0x1e222000, 0x540001eb,
                  0x5e0c04c1, 0x1e245002, 0x1e261003, 0x1e220800, 0x1e230822, 0x1e223800, 0x1e20c000,
                  0x1e221002, 0x1e222000, 0x540000aa, 0xbd405e02, 0x1e220821, 0x6e0c0426, 0x3d802be6):
            emit(w)
        emit(B(here(), ortho_site + 4))
        fs_put(ortho_site, [B(ortho_site, start)], 'Layout2 ortho canvas height scaled by (16/9) / aspect when screen aspect is active')

    # Layout view draw (main+0x773b90): builds the screen-space OrthoProjection (-W/2..W/2, -H/2..H/2) at +0x398 (orig ldp s0, s1, [x0]) into the 0x90-byte UBO copied to Layout2.
    # Scales 16:9 viewport height s1 (W >= 1000) by state +0x5c (k = (16/9) / aspect) so 2D HUD widgets render 1:1 without vertical stretch. x16/x17, s2..s4 and nzcv are free there.
    vo_fn = ctx.others.get('layout view ortho')
    if vo_fn is not None:
        vo_site = vo_fn + 0x398
        fs_site(vo_site, '0004402d')   # ldp s0, s1, [x0]
        start = here()
        emit(0x2d400400)
        emit(ADRP(16, here(), FS_STATE_OFF))
        for w in (0xb9404a11, 0x34000211, 0x52a88f51, 0x1e270222, 0x1e222000, 0x5400018b,
                  0x1e245002, 0x1e261003, 0x1e220804, 0x1e230822, 0x1e223884, 0x1e20c084,
                  0x1e221002, 0x1e222080, 0x5400006a, 0xbd405e02, 0x1e220821):
            emit(w)
        emit(B(here(), vo_site + 4))
        fs_put(vo_site, [B(vo_site, start)], 'Layout view ortho height scaled by (16/9) / aspect when screen aspect is active')

    # sead::PerspectiveProjection::doUpdateMatrixImpl_ (main+0x3485cc0): for ~16:9 projections (|aspect - 16/9| <= 0.01), divides aspect by k (to host r = 1920/oh) and widens fovyTan by k (when <= state +0x60 tol) for true Vert+ 3D.
    proj_fn = ctx.others.get('perspective proj')
    if proj_fn is not None:
        proj_site = proj_fn
        fs_site(proj_site, '0084552d')   # ldp s0, s1, [x0, #0xac]
        start = here()
        emit(0x2d558400)
        emit(ADRP(16, here(), FS_STATE_OFF))
        for w in (0xb9404a11, 0x34000231, 0xbd405e03, 0xbd406204, 0x5291c731, 0x72a7fc71, 0x1e270225, 0x1e253825,
                  0x1e20c0a5, 0x529ae151, 0x72a78471, 0x1e270226, 0x1e2620a0, 0x540000ac, 0x1e231821, 0x1e2420a0,
                  0x5400004c, 0x1e230800):
            emit(w)
        emit(B(here(), proj_site + 4))
        fs_put(proj_site, [B(proj_site, start)], 'PerspectiveProjection aspect and Vert+ fovyTan scaled by (16/9) / aspect when screen aspect is active')
    # Camera projection update (main+0x33a8c0): inlined sead::PerspectiveProjection update at +0xf6c (main+0x33b82c, orig ldp s0, s1, [x2, #0xac]).
    # Scales aspect and fovyTan for ~16:9 projections (|aspect - 16/9| <= 0.01) so gameplay 3D view maintains 1:1 circular aspect on any screen ratio.
    cam_fn = ctx.others.get('camera update')
    if cam_fn is not None:
        cam_site = cam_fn + 0xf6c
        fs_site(cam_site, '4084552d')   # ldp s0, s1, [x2, #0xac]
        start = here()
        emit(0x2d558440)
        emit(ADRP(16, here(), FS_STATE_OFF))
        for w in (0xb9404a11, 0x34000231, 0xbd405e03, 0xbd406204, 0x5291c731, 0x72a7fc71, 0x1e270225, 0x1e253825,
                  0x1e20c0a5, 0x529ae151, 0x72a78471, 0x1e270226, 0x1e2620a0, 0x540000ac, 0x1e231821, 0x1e2420a0,
                  0x5400004c, 0x1e230800):
            emit(w)
        emit(B(here(), cam_site + 4))
        fs_put(cam_site, [B(cam_site, start)], 'Camera update projection aspect and Vert+ fovyTan scaled by (16/9) / aspect when screen aspect is active')

    # Device projection matrix (main+0x23b910): inlined sead::PerspectiveProjection update at +0x98 (main+0x23b9a8, orig ldp s0, s3, [x0, #0xac]).
    # Scales aspect (s3) and fovyTan (s0) for ~16:9 projections.
    dev_fn = ctx.others.get('device proj')
    if dev_fn is not None:
        dev_site = dev_fn + 0x98
        fs_site(dev_site, '008c552d')   # ldp s0, s3, [x0, #0xac]
        start = here()
        emit(0x2d558c00)
        emit(ADRP(16, here(), FS_STATE_OFF))
        for w in (0xb9404a11, 0x34000231, 0xbd405e07, 0xbd406206, 0x5291c731, 0x72a7fc71, 0x1e270222, 0x1e223862,
                  0x1e20c042, 0x529ae151, 0x72a78471, 0x1e270221, 0x1e212040, 0x540000ac, 0x1e271863, 0x1e262040,
                  0x5400004c, 0x1e270800):
            emit(w)
        emit(B(here(), dev_site + 4))
        fs_put(dev_site, [B(dev_site, start)], 'Device projection aspect and Vert+ fovyTan scaled by (16/9) / aspect when screen aspect is active')


    # Layout2 pane matrix (main+0x14e9980): for fullscreen PicturePanes (width >= 1000, height >= 700, ~16:9), scales Y matrix row by state +0x5c (k = (16/9) / aspect) so full-screen faders cover the expanded canvas without letterboxing.
    calc_fn = ctx.others.get('layout calc matrix')
    if calc_fn is not None:
        calc_site = calc_fn + 0x19c
        fs_site(calc_site, '6042883c')   # stur q0, [x19, #0x84]
        start = here()
        emit(ADRP(16, here(), FS_STATE_OFF))
        for w in (0xb9404a11, 0x34000351, 0xb940aab1, 0x53166631, 0x7100063f, 0x540002c1, 0x2d4b0ea2,
                  0x52a88f51, 0x1e270224, 0x1e242040, 0x54000224, 0x52a885f1, 0x1e270224, 0x1e242060,
                  0x540001a4, 0x1e245004, 0x1e261005, 0x1e240844, 0x1e250865, 0x1e253884, 0x1e20c084,
                  0x52a86911, 0x1e270225, 0x1e252080, 0x5400006a, 0xbd405e02, 0x4f829000, 0x3c884260):
            emit(w)
        emit(B(here(), calc_site + 4))
        fs_put(calc_site, [B(calc_site, start)], 'Layout2 fullscreen picture panes scaled by (16/9) / aspect when screen aspect is active')

def dynamic_resolution(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    site = ctx.others.get('dynamic resolution')
    if site is None or ctx.others.get('dynamic resolution update') is None: return   # not both found in this build (a red line from the locator): the game's own dynamic resolution
    fs_site(site, '017c40bd')   # ldr s1,[x0,#0x7c]
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in drs_controller: emit(w)
    fs_put(site, [B(site, start)], 'dynamic resolution level: 0 (full resolution), or with state +0x40 (DM_DYNAMIC_RESOLUTION) a climb on the load measured at each level')
    ctx.capabilities.add('DYNAMIC_RESOLUTION')
    ctx.render_scale = 2   # DM_RENDER_SCALE up to 2.0 of level 0 (0.75 of the output: 1.333 is native); the stub holds it at 1.0 of the output
    output_4k(ctx)
    screen_shape(ctx)

# 3840x2160: a render scale above 1.333 (state +0x10, DM_RENDER_SCALE) makes the output the game's own 3840x2160 instead of 2560x1440 docked, and the level stub above draws
# the 3D views at 1080 x the render scale lines of it (2.0: 3840x2160, native). Four places size the output for it, each x 1.5 then (a multiple of 4), and one budget x 2.25:
# - the frame buffer: main+0x1087f40 (v131072) keeps the output at +0x10 of the graphics system and maps it to the game's list of seven (640x480 .. 3840x2160). The game's
#   init (main+0x1087b70) sets it from its start parameters ([x1], 2560x1440 docked), before its call; on a change of mode or tier main+0x6502e0 sets it again from the mode's
#   size (w21 x w22), after the pick at main+0x112c5e0 that holds it to the list (3840x2160 docked at tier 0, 2560x1440 at tier 1). x16, x17, s0 and s1 are free at both calls
# - the window textures: the graphics init (main+0x346be50) hands the window its size from the config ([x19+0x9c], 2560x1440 docked) as floats (ldp s0, s1 at +0x3fc); x9,
#   s2 and s3 are free there. Without it the frame is 3840x2160 and every present crops a 2560x1440 window texture
# - the render-target memory: the per-frame render targets (main+0x3ed00) take blocks from a budget the app object holds at +0x5b8 (0x13100000, 305 MB) in blocks of +0x5c0
#   (64 MB). A 3840x2160 frame needs 2.25 times the 2560x1440 one: without it the allocation fails at the first frame of play and the game reads a null block (main+0x404fc).
#   The app's graphics init (main+0x36ae9d0) copies both into the allocator's setup after +0x88 (ldr x21, [x19, #0x590]); x9, x10, s0..s2 are free there
# The 3D size: the view-size update (main+0x31d3200) and the level's scale both scale by 1440 / the output's height, so the level stub writes 1.5 x 0.75 x the render scale.
# The upscaler (roulibr) has no 3840x2160 variant; at 2.0 it has nothing to upscale. 1.333 or less keeps every size the game's own
above_4_3 = (0xbd401200, 0x1e2d1001, 0x1e210800, 0x1e2e1001, 0x1e212000)   # ldr s0,[x16,#0x10]; s0 = it x 0.75; fcmp s0, 1.0
init_stub = (0xb9000a68,) + above_4_3 + (0x5400018d, 0x1e2f1000,              # the replaced str w8, [x19, #8]; b.le the call (1.333 or less, or NaN); s0 = 1.5
             0x29404430, 0x1e220201, 0x1e200821, 0x1e380030, 0x121e7610,      # width x 1.5, a multiple of 4
             0x1e220221, 0x1e200821, 0x1e380031, 0x121e7631, 0x29004430)      # height x 1.5, a multiple of 4; back to the parameters
mode_stub = above_4_3 + (0x5400014d, 0x1e2f1000,                              # b.le the replaced ldp; s0 = 1.5
             0x1e2202a1, 0x1e200821, 0x1e380035, 0x121e76b5,                  # width x 1.5, a multiple of 4
             0x1e2202c1, 0x1e200821, 0x1e380036, 0x121e76d6, 0x297f27a8)      # height x 1.5, a multiple of 4; the replaced ldp w8, w9, [x29, #-8]
window_stub = (0x2d538660, 0xbd401122, 0x1e2d1003, 0x1e230842, 0x1e2e1003, 0x1e232040, 0x5400018d, 0x1e2f1002,   # the size [x19+0x9c] (ints in s0, s1); above 1.333: x 1.5
               0x7e21d803, 0x1e220863, 0x1e390069, 0x121e7529, 0x1e270120,                                       # width x 1.5, a multiple of 4
               0x7e21d823, 0x1e220863, 0x1e390069, 0x121e7529, 0x1e270121)                                       # height x 1.5, a multiple of 4
budget_stub = (0xbd401120, 0x1e2d1001, 0x1e210800, 0x1e2e1001, 0x1e212000, 0x540001cd, 0x1e205000,              # above 1.333: x 2.25
               0xf942de6a, 0x9e230142, 0x1e200842, 0x9e39004a, 0x9270bd4a, 0xf902de6a,                           # the budget (+0x5b8) x 2.25, a multiple of 64 KB
               0xf942e26a, 0x9e230142, 0x1e200842, 0x9e39004a, 0x9270bd4a, 0xf902e26a,                           # the block size (+0x5c0) x 2.25, a multiple of 64 KB
               0xf942ca75)                                                                                       # the replaced ldr x21, [x19, #0x590]
def output_4k(ctx):
    names = ('output size init', 'output size', 'window size', 'graphics init')
    init, fn, win, gfx = (ctx.others.get(k) for k in names)
    if None in (init, fn, win, gfx): return   # not all found in this build (a red line from the locator): the game's own sizes, 1.333 at most
    why = ' x 1.5 when the render scale is above 1.333 (state +0x10, DM_RENDER_SCALE): the game\'s 3840x2160 docked'
    for site, orig, reg, words, what in ((init + 0xf4, '680a00b9', 16, init_stub, 'output size at start: the parameters\' size, before the call at +0xf8' + why),
                                         (fn + 0x300, 'a8277f29', 16, mode_stub, 'output size on a mode change: the mode\'s size, after the pick at +0x2fc' + why),
                                         (win + 0x3fc, '6086532d', 9, window_stub, 'window textures\' size' + why),
                                         (gfx + 0x88, '75ca42f9', 9, budget_stub, 'render-target memory budget and block size x 2.25 when the render scale is above 1.333')):
        ctx.site(site, orig)
        start = ctx.here()
        if words is init_stub: ctx.emit(words[0]); words = words[1:]   # the replaced store first: the state page's adrp after it
        ctx.emit(ADRP(reg, ctx.here(), ctx.state))
        for w in words: ctx.emit(w)
        ctx.emit(B(ctx.here(), site + 4))
        ctx.put(site, [B(site, start)], what)

MATCH_FRAME_STEP = {'main': [
    {'name': 'frame ratio from the host\'s step', 'size': 0x9b4, 'fingerprints': ['6ae2aff5344d14568e4dbaf93455e2d8278384bf892ed6c6eca87fef98fbcd1d'], 'stub': frame_step,   # v131072 main+0x6e6be0
     'others': {'dynamic resolution': {'size': 0x294, 'fingerprints': ['7af6ceb0aedf8e0c17dc08ce17fcd6a7cba6d394a0d09e3b504c6d668dc418e7']},   # v131072 main+0x8065e0
                'dynamic resolution update': {'size': 0xb24, 'fingerprints': ['5a423697838976baf286cffa5e2ceef0d4e037abbcd9d371e90e9e702d61b3d4']},   # main+0x805aa0
                'output size init': {'size': 0x2fc, 'fingerprints': ['f102ed9f80a4fc711650f4a86d11fe36602ecb330f422af96a4bad212dab5382']},   # main+0x1087b70
                'output size': {'size': 0x554, 'fingerprints': ['c0cab0dbf6f0644635315a356f8fd23a4701515c4ab4775d52191835b1a12e3c']},   # main+0x6502e0
                'window size': {'size': 0x6f0, 'fingerprints': ['db697988f57115f6aa10a89a8b6b765629fc12a5be32a02c196dc2c1329ab095']},   # main+0x346be50
                'graphics init': {'size': 0x858, 'fingerprints': ['83be7b818af92490839ec68669d6ee56d396e6bf4028c4c5a022e403e50d53ac']},   # main+0x36ae9d0
                'graphics system init': {'size': 0x570, 'fingerprints': ['f2c5558922a471ab585d374cc9293013d48da1562d43169367efdc8ea90a3fe8']},   # main+0x1202ce0
                'scene app init': {'size': 0x273c, 'fingerprints': ['2227b93a9fa9dd0fd9aeb64359649df6e2ade519a8e47fa560f840efcdb5d7e7']},   # main+0x31f3890
                'base scene defaults': {'size': 0x3cc, 'fingerprints': ['4d34ae0b1d0fa05603a24e64aae393040502bdfda2fc053a5c3c02ffda42053e']},   # main+0x108b300
                'display mgr defaults': {'size': 0x4e0, 'fingerprints': ['871e4f9e24b2007d3a9ddbb061b6d1a3709c05f623b356daba35fe1dfeb2004c']},   # main+0x36b2bc0
                'base res read': {'size': 0x1a0, 'fingerprints': ['c49c68fad34b6fce5c0dc0f519f5ddda261ad56778917dc2a711553a10cf4db1']},   # main+0xe82f30
                'display target a': {'size': 0x58, 'fingerprints': ['125411e6b2df56ae4e8c0f9c16f134b4ed9247aca4e426c72b406b1f838bfbb9']},   # main+0xd565a0
                'display target b': {'size': 0x1a8, 'fingerprints': ['212c9a344038bdcf99e4a462ecbe1bb58a2b6374d364debd0d0a0664e1dc1175']},   # main+0xebf370
                'display target c': {'size': 0x188, 'fingerprints': ['0b669aaafc4c17cef5c96ac9e4054895152937e9c780f0c72893973256e9dca7']},   # main+0xf96310
                'layout ortho': {'size': 0x7b0, 'fingerprints': ['fed0ce1f2ad6c8f6118a974ec7d5d5a346194a4c10a0fc01f894cfec3d0a1b68']},   # main+0x1520c80
                'layout view ortho': {'size': 0x62c, 'fingerprints': ['103de33fb929cda858c2fbd57b726e6e1bca705bad66de872701819fbf5c6089']},   # main+0x773b90
                'perspective proj': {'size': 0xb8, 'fingerprints': ['e36f61aa83e94dfacc860ab4dd60dd1362cdab40fa490aee9e921a7ae0f3156d']},
                'camera update': {'size': 0x1648, 'fingerprints': ['66a50abf2237dee694c40d6a2371071d62e91379d40b643869d680f597bfab02']},
                'device proj': {'size': 0x3b0, 'fingerprints': ['ab5c2809cdbc7f9e30b966872350ac69301aa246a9169610d038ea9480bde910']},   # main+0x3485cc0
                'layout calc matrix': {'size': 0x208, 'fingerprints': ['0e057804c3c8c7d14ff833983335d834e0bd7505e05263e9c065472b9d206c74']}}},   # main+0x14e9980
]}

# The movie player's pictures per frame. Once a frame the player's update (main+0x3b5ca60 on v131072) adds the frame's time (the time object's +0x18, the frame ratio / 60 s, times
# 60) to a count at +0x8, takes its whole pictures (the movie's rate at the player's +0x324; the title's and the opening's are 60 fps) and advances that many (main+0x3b61ea0 pops them from its
# queue and shows the last), but never more than the player's +0x20 (csel at main+0x3b5cb2c), and the count keeps what was left. The constructor (main+0x3b5cec0) sets +0x20 to
# 1, or to 2 when its last argument is 2 or more (cmp w27, #2; cinc w8, w28, ge at +0x1c4, w28 = 1), and the queue's size at +0x50 to twice that; the game's one caller passes 1
# (main+0x3b5c55c). So a frame of two vsyncs shows one picture where the movie had two, the picture falls behind for good (the count only grows), and the movie's sound, a stream of
# the sound engine on real time, runs ahead and ends before the picture: at a 30 fps frame step a movie played at exactly 0.500 of its speed (58.00 s of movie in 115.95 s) with
# the count at 1,350 pictures after 45 s. The console holds one vsync a frame in its movies, so the limit never shows there; here the frame step hands the game steps of 2 and 3.
# The cut gives the constructor's own value for 2 (+0x20 = 2, +0x50 = 4), so a frame of two vsyncs shows every second picture and a movie that fell behind catches up at two
# pictures a frame: at the 30 fps frame step 1.000 (95.00 s in 94.97 s). 3, the frame step's largest hold, is no value of the game's: forced, the game stopped at the movie's
# start with a copy to a null pointer in sdk (cause not looked into), so frames held 3 vsyncs still lose a picture each until shorter frames catch up
movie_pictures = 'movie pictures a frame: up to 2, the constructor\'s value for an argument of 2 or more, whatever its caller passes (1)'
MATCH_CUTS = {'main': [
    {'name': movie_pictures, 'size': 828, 'fingerprints': ['f61ad468b6b4e1d574fe8678f5a12dfc60e1aab71be7375142a4b48b0d73ce19'],   # v131072 main+0x3b5cec0
     'cuts': [(452, '88b79c1a', '48008052', movie_pictures + ' (cinc w8, w28, ge → mov w8, #2; as v131072 main+0x3b5d084)')]},
]}

BINDING = [
    {'what': 'movie pictures a frame: up to 2', 'now': 'game', 'goal': 'game', 'purpose': 'frame rate',
     'why': "the game's own movie player constructor, found by its function's fingerprint on any build that keeps the function; other games of this engine are unchecked",
     'checked': 'v131072 main: one function with this fingerprint, the constructor, its one caller, the update and the advance read by disassembly; the limit and the count read in play with DM_PROBE, the opening movie timed at a 30 fps frame step without and with the cut (2026-11-12)'},
    {'what': 'frame ratio from the host\'s step', 'now': 'game', 'goal': 'game', 'purpose': 'frame rate',
     'why': "the game's own frame-ratio division, found by its function's fingerprint on any build that keeps the function",
     'checked': 'v131072 main: one function with this fingerprint, the site and its free registers read by disassembly (2026-11-08)'},
    {'what': 'dynamic resolution: full size, or a climb on the load measured at each level', 'now': 'game', 'goal': 'game', 'purpose': 'rendering',
     'why': "the game's own dynamic-resolution level function and update, found by their functions' fingerprints on any build that keeps both; switchable (DM_DYNAMIC_RESOLUTION)",
     'checked': 'v131072 main: one function with each fingerprint (the level function a leaf, x2..x11 / x16 / x17 / s0..s2 free), its callers, the update and the controller fields read by disassembly, the fields read in play (2026-11-08); the climb run natively against a model of the update and in play to full size (2026-11-09)'},
    {'what': 'screen shape: render heights, base resolution, and Layout2 ortho projections scaled from 16:9 (DM_SCREEN_ASPECT)', 'now': 'game', 'goal': 'game', 'purpose': 'rendering',
     'why': "all fifteen display, scene-default, base-resolution, perspective projection, and Layout2 sites matched by their functions' fingerprints on any build that keeps them; inactive when oh is 0 (16:9)",
     'checked': 'v131072 main: one function per fingerprint, free registers read at each site (2026-11-13); verified in play at 16:9, 16:10, and 4:3 with Vert+ framing and unstretched HUD widgets (heart1 68x33 across all three)'},
]
