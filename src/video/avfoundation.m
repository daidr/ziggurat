/* On macOS, AVFoundation plays the video (src/video/avfoundation.zig
   wraps it as an engine): an AVPlayer, which decodes in hardware
   (VideoToolbox), plays the sound and keeps the clock, and an
   AVPlayerItemVideoOutput, from which each frame the window builds takes
   the picture due as it shows, a CVPixelBuffer in NV12 backed by an
   IOSurface, which the Metal renderer wraps as textures without a copy. A
   thread of the engine's watches how loading and playing go, and wakes the
   window as that changes or a picture comes while none is asked for. Bytes
   in memory reach the player through an AVAssetResourceLoader, whose
   delegate answers on a queue of its own from the bytes, without a file. */
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>
#include "image_resource.h"

/* The states, as ziggurat_view_video.State numbers them. */
enum { ZV_LOADING, ZV_READY, ZV_BUFFERING, ZV_ENDED, ZV_FAILED };

typedef void (*ZvWake)(void *context);

/* Answers an asset's resource loader from bytes in memory: what they are,
   and those asked for. */
@interface ZigVideoDataLoader : NSObject <AVAssetResourceLoaderDelegate>
@property(nonatomic, strong) NSData *bytes;
@property(nonatomic, copy) NSString *contentType;
@end

@implementation ZigVideoDataLoader
- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request {
    (void)resourceLoader;
    NSData *bytes = self.bytes;
    if (!bytes) return NO;
    AVAssetResourceLoadingContentInformationRequest *info = request.contentInformationRequest;
    if (info) {
        info.contentType = self.contentType;
        info.contentLength = (long long)bytes.length;
        info.byteRangeAccessSupported = YES;
    }
    AVAssetResourceLoadingDataRequest *data = request.dataRequest;
    if (data) {
        long long length = (long long)bytes.length;
        long long start = data.currentOffset;
        long long end = data.requestedOffset + (long long)data.requestedLength;
        if (data.requestsAllDataToEndOfResource) end = length;
        if (start < 0) start = 0;
        if (start > length) start = length;
        if (end > length) end = length;
        if (end > start) [data respondWithData:[bytes subdataWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end - start))]];
    }
    [request finishLoading];
    return YES;
}
@end

@interface ZigVideoEngine : NSObject {
@public
    AVPlayer *player;
    AVPlayerItem *item;
    AVPlayerItemVideoOutput *output;
    ZigVideoDataLoader *loader;
    dispatch_queue_t loader_queue;
    NSThread *watcher;
    /* The CVPixelBuffer the last frame returned, retained. */
    CVPixelBufferRef buffer;
    uint32_t width, height, matrix;
    uint64_t interval;
    NSLock *lock;
    /* Under lock: the wake, the state, and what the app asked for. */
    ZvWake wake;
    void *wake_context;
    int state;
    bool playing, looping, closed, woke;
    float rate;
    char failure[256];
    atomic_bool quit;
    dispatch_semaphore_t done;
}
@end
@implementation ZigVideoEngine
@end

static CMTime time_of(uint64_t ns) { return CMTimeMake((int64_t)ns, 1000000000); }
static bool known(CMTime t) { return (t.flags & kCMTimeFlags_Valid) && !(t.flags & (kCMTimeFlags_Indefinite | kCMTimeFlags_PositiveInfinity | kCMTimeFlags_NegativeInfinity)) && t.timescale > 0; }
static uint64_t ns_of(CMTime t) {
    if (!known(t) || t.value < 0) return 0;
    return (uint64_t)((double)t.value / (double)t.timescale * 1e9);
}

/* Seeks to `at` exactly, under the lock. */
static void seek_locked(ZigVideoEngine *e, uint64_t at) {
    [e->player seekToTime:time_of(at) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    e->woke = false;
}

/* Reads the item's state, under the lock: a loop seeks back at the end. */
static void poll_locked(ZigVideoEngine *e) {
    if (e->closed || e->state == ZV_FAILED) return;
    switch (e->item.status) {
    case AVPlayerItemStatusFailed: {
        e->state = ZV_FAILED;
        NSString *message = e->item.error.localizedDescription ?: @"AVFoundation could not play the video";
        snprintf(e->failure, sizeof e->failure, "%s", message.UTF8String ?: "");
        return;
    }
    case AVPlayerItemStatusReadyToPlay: break;
    default: return; /* loading */
    }
    /* Ready once its first picture shows (zv_avf_frame). */
    if (e->state == ZV_LOADING) return;
    CMTime duration = e->item.duration;
    uint64_t at = ns_of(e->item.currentTime);
    if (known(duration) && e->playing && at + 1000000 >= ns_of(duration)) {
        if (e->looping) {
            seek_locked(e, 0);
            e->player.rate = e->rate;
            return;
        }
        if (e->state != ZV_ENDED) {
            e->state = ZV_ENDED;
            [e->player pause];
        }
        return;
    }
    if (e->state == ZV_ENDED) return;
    e->state = e->playing && e->player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate ? ZV_BUFFERING : ZV_READY;
}

/* The watching thread: every 25 ms the item's state, and whether a
   picture came that no frame took, which wakes the window. */
static void watch(ZigVideoEngine *e) {
    while (!atomic_load(&e->quit)) {
        @autoreleasepool {
            [e->lock lock];
            int before = e->state;
            poll_locked(e);
            bool wakes = e->state != before;
            if (!e->woke && !e->closed && e->item.status == AVPlayerItemStatusReadyToPlay && [e->output hasNewPixelBufferForItemTime:e->item.currentTime]) {
                e->woke = true;
                wakes = true;
            }
            ZvWake wake = wakes ? e->wake : NULL;
            void *context = e->wake_context;
            [e->lock unlock];
            if (wake) wake(context);
        }
        usleep(25000);
    }
    dispatch_semaphore_signal(e->done);
}

static NSString *content_type(const uint8_t *bytes, size_t length) {
    if (length >= 12 && memcmp(bytes + 4, "ftyp", 4) == 0 && memcmp(bytes + 8, "qt  ", 4) == 0) return @"com.apple.quicktime-movie";
    return @"public.mpeg-4";
}

/* 0 opened, 1 no AVFoundation, 2 not a URL. */
int zv_avf_open(const char *url, const uint8_t *bytes, size_t length, void **out) {
    @autoreleasepool {
        if (!NSClassFromString(@"AVPlayer") || !NSClassFromString(@"AVPlayerItemVideoOutput")) return 1;
        ZigVideoEngine *e = [ZigVideoEngine new];
        e->lock = [NSLock new];
        e->rate = 1;
        e->done = dispatch_semaphore_create(0);
        AVURLAsset *asset;
        if (bytes) {
            static atomic_uint_fast64_t last;
            uint64_t number = atomic_fetch_add(&last, 1) + 1;
            NSURL *data_url = [NSURL URLWithString:[NSString stringWithFormat:@"ziggurat-video://data/%llu.mp4", (unsigned long long)number]];
            asset = [AVURLAsset URLAssetWithURL:data_url options:nil];
            e->loader = [ZigVideoDataLoader new];
            /* The bytes stay as they are while the player is open. */
            e->loader.bytes = [NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO];
            e->loader.contentType = content_type(bytes, length);
            e->loader_queue = dispatch_queue_create("ziggurat.video.data", DISPATCH_QUEUE_SERIAL);
            [asset.resourceLoader setDelegate:e->loader queue:e->loader_queue];
        } else {
            NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
            if (!u) return 2;
            asset = [AVURLAsset URLAssetWithURL:u options:nil];
        }
        e->item = [AVPlayerItem playerItemWithAsset:asset];
        NSDictionary *attributes = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        e->output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attributes];
        [e->item addOutput:e->output];
        e->player = [AVPlayer playerWithPlayerItem:e->item];
        /* The player pauses at the end, rather than stand at the end
           playing, for the thread to see; it loops by a seek. */
        e->player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        e->player.preventsDisplaySleepDuringVideoPlayback = YES;
        e->watcher = [[NSThread alloc] initWithBlock:^{
            watch(e);
        }];
        [e->watcher start];
        *out = (__bridge_retained void *)e;
        return 0;
    }
}

static ZigVideoEngine *engine_of(void *p) { return (__bridge ZigVideoEngine *)p; }

/* AVFoundation reports how loading goes on the main queue. A process with
   no run loop running there, as a test's, runs what it queued when asked
   for the state or a picture; an app's run loop runs it already. */
static void pump(void) {
    if (!NSThread.isMainThread) return;
    CFRunLoopRef loop = CFRunLoopGetMain();
    CFStringRef mode = CFRunLoopCopyCurrentMode(loop);
    if (mode) {
        CFRelease(mode);
        return;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
}

void zv_avf_set_wake(void *p, ZvWake wake, void *context) {
    ZigVideoEngine *e = engine_of(p);
    [e->lock lock];
    e->wake = wake;
    e->wake_context = context;
    [e->lock unlock];
}

/* The YUV matrix a pixel buffer's attachment says, or for none that of its
   size. */
static uint32_t matrix_of(CVPixelBufferRef buffer) {
    uint32_t m = CVPixelBufferGetHeight(buffer) >= 720 ? 1 : 0;
    CFTypeRef value = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, NULL);
    if (value) {
        if (CFEqual(value, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) m = 1;
        else if (CFEqual(value, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) m = 0;
        else if (CFEqual(value, kCVImageBufferYCbCrMatrix_ITU_R_2020)) m = 2;
        CFRelease(value);
    }
    if (CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) m += 3;
    return m;
}

/* The picture due `ahead` ns from now, and never one from before now: a
   test's clock stands still, and the player's runs on. Returns whether
   there is one; `changed` whether it is a new one. */
bool zv_avf_frame(void *p, uint64_t ahead, ZiVideoPicture *picture, bool *changed) {
    ZigVideoEngine *e = engine_of(p);
    @autoreleasepool {
        pump();
        *changed = false;
        /* The output may have a picture before the item knows its
           duration: ready is both. */
        if (!e->buffer && e->item.status != AVPlayerItemStatusReadyToPlay) return false;
        CMTime at = [e->output itemTimeForHostTime:CACurrentMediaTime() + (double)ahead / 1e9];
        if ([e->output hasNewPixelBufferForItemTime:at]) {
            CVPixelBufferRef buffer = [e->output copyPixelBufferForItemTime:at itemTimeForDisplay:NULL];
            if (buffer) {
                /* What drew the last one holds it still (the renderer's
                   textures) as long as it needs it. */
                if (e->buffer) CVPixelBufferRelease(e->buffer);
                e->buffer = buffer;
                e->width = (uint32_t)CVPixelBufferGetWidth(buffer);
                e->height = (uint32_t)CVPixelBufferGetHeight(buffer);
                e->matrix = matrix_of(buffer);
                *changed = true;
                [e->lock lock];
                if (e->state == ZV_LOADING) e->state = ZV_READY;
                [e->lock unlock];
            }
        }
        [e->lock lock];
        e->woke = false;
        [e->lock unlock];
        if (!e->buffer) return false;
        *picture = (ZiVideoPicture){.width = e->width, .height = e->height, .format = ZI_VIDEO_NV12, .matrix = e->matrix, .native = e->buffer};
        return true;
    }
}

/* The planes of a pixel buffer in memory, for the CPU renderer, locked
   until zv_avf_unlock. */
bool zv_avf_lock(void *buffer, const uint8_t **planes, uint32_t *strides) {
    CVPixelBufferRef b = (CVPixelBufferRef)buffer;
    if (CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return false;
    for (size_t i = 0; i < 2; i++) {
        planes[i] = CVPixelBufferGetBaseAddressOfPlane(b, i);
        strides[i] = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(b, i);
        if (!planes[i]) {
            CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
            return false;
        }
    }
    return true;
}
void zv_avf_unlock(void *buffer) { CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)buffer, kCVPixelBufferLock_ReadOnly); }

uint64_t zv_avf_interval(void *p) {
    ZigVideoEngine *e = engine_of(p);
    if (e->interval == 0) {
        @autoreleasepool {
            e->interval = 1000000000ull / 60;
            NSArray<AVAssetTrack *> *tracks = [e->item.asset tracksWithMediaType:AVMediaTypeVideo];
            float fps = tracks.count > 0 ? tracks.firstObject.nominalFrameRate : 0;
            /* Asked for twice as often, so that a frame shows at the
               refresh after it came due, not up to one later. */
            if (fps > 1) e->interval = (uint64_t)(1e9 / fps / 2);
        }
    }
    return e->interval;
}

int zv_avf_state(void *p, char *failure, size_t length) {
    ZigVideoEngine *e = engine_of(p);
    @autoreleasepool {
        pump();
    }
    [e->lock lock];
    int state = e->state;
    if (failure && length) snprintf(failure, length, "%s", e->failure);
    [e->lock unlock];
    return state;
}

void zv_avf_size(void *p, uint32_t *size) {
    ZigVideoEngine *e = engine_of(p);
    size[0] = e->width;
    size[1] = e->height;
}
uint64_t zv_avf_duration(void *p) {
    @autoreleasepool {
        return ns_of(engine_of(p)->item.duration);
    }
}
uint64_t zv_avf_position(void *p) {
    @autoreleasepool {
        return ns_of(engine_of(p)->item.currentTime);
    }
}
void zv_avf_play(void *p) {
    ZigVideoEngine *e = engine_of(p);
    @autoreleasepool {
        [e->lock lock];
        e->playing = true;
        if (e->state == ZV_ENDED) {
            e->state = ZV_READY;
            seek_locked(e, 0);
        }
        e->player.rate = e->rate;
        [e->lock unlock];
    }
}
void zv_avf_pause(void *p) {
    ZigVideoEngine *e = engine_of(p);
    @autoreleasepool {
        [e->lock lock];
        e->playing = false;
        [e->player pause];
        [e->lock unlock];
    }
}
void zv_avf_seek(void *p, uint64_t at) {
    ZigVideoEngine *e = engine_of(p);
    @autoreleasepool {
        [e->lock lock];
        if (e->state == ZV_ENDED) e->state = ZV_READY;
        seek_locked(e, at);
        [e->lock unlock];
    }
}
void zv_avf_set_loop(void *p, bool looping) {
    ZigVideoEngine *e = engine_of(p);
    [e->lock lock];
    e->looping = looping;
    [e->lock unlock];
}
void zv_avf_set_rate(void *p, double rate) {
    ZigVideoEngine *e = engine_of(p);
    @autoreleasepool {
        [e->lock lock];
        e->rate = (float)rate;
        if (e->playing && e->state != ZV_ENDED) e->player.rate = e->rate;
        [e->lock unlock];
    }
}
void zv_avf_set_volume(void *p, double volume) {
    @autoreleasepool {
        engine_of(p)->player.volume = (float)volume;
    }
}
void zv_avf_set_muted(void *p, bool muted) {
    @autoreleasepool {
        engine_of(p)->player.muted = muted;
    }
}

/* Stops the thread and the player and frees them. The renderer's textures
   hold the pixel buffer showing as long as they draw it; the player kept
   the picture as BGRA before. */
void zv_avf_close(void *p) {
    ZigVideoEngine *e = (__bridge_transfer ZigVideoEngine *)p;
    @autoreleasepool {
        [e->lock lock];
        e->closed = true;
        e->wake = NULL;
        [e->lock unlock];
        atomic_store(&e->quit, true);
        dispatch_semaphore_wait(e->done, DISPATCH_TIME_FOREVER);
        [e->player pause];
        [e->player replaceCurrentItemWithPlayerItem:nil];
        [e->item removeOutput:e->output];
        if (e->loader) e->loader.bytes = nil;
        if (e->buffer) CVPixelBufferRelease(e->buffer);
        e->buffer = NULL;
        e->player = nil;
        e->item = nil;
        e->output = nil;
        e->loader = nil;
        e->watcher = nil; /* whose block holds the engine */
    }
}
