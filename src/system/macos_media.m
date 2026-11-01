/* MPNowPlayingInfoCenter and MPRemoteCommandCenter for system.NowPlaying:
   the same znp_set entry point as the MPRIS adapter. Control Center's Now
   Playing, the lock screen, the menu bar's media controls and the media
   keys of keyboards and headsets show the info and send commands. Commands
   reach Zig on the main queue, never inside a handler. Compiled with ARC. */
#import <AppKit/AppKit.h>
#import <MediaPlayer/MPMediaItem.h>
#import <MediaPlayer/MPNowPlayingInfoCenter.h>
#import <MediaPlayer/MPRemoteCommandCenter.h>
#import <MediaPlayer/MPRemoteCommand.h>
#import <MediaPlayer/MPRemoteCommandEvent.h>
#include <stdint.h>
#include <string.h>

typedef struct ZnpInfo {
    const char *title, *artist, *album;
    const uint8_t *artwork;
    size_t artwork_len;
    int64_t duration_us, position_us;
    double rate;
    int state; /* 0 playing, 1 paused, 2 stopped */
    uint32_t commands;
} ZnpInfo;
typedef void (*ZnpDeliver)(uint32_t raw, int64_t position_us);

/* Command bits as now_playing.zig numbers them; 4 is the play/pause key. */
enum { BIT_PLAY = 1, BIT_PAUSE = 2, BIT_TOGGLE = 4, BIT_STOP = 8, BIT_NEXT = 16, BIT_PREVIOUS = 32, BIT_SEEK = 64 };

static ZnpDeliver deliver_command;
static NSMutableArray *targets;

static void fire(uint32_t raw, int64_t position_us) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (deliver_command) deliver_command(raw, position_us);
    });
}
static NSString *text(const char *value) {
    NSString *string = value ? [NSString stringWithUTF8String:value] : nil;
    return [string length] ? string : nil;
}

static void remove_targets(void) {
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    for (MPRemoteCommand *command in @[center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand, center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand]) {
        for (id target in targets) [command removeTarget:target];
        command.enabled = NO;
    }
    targets = nil;
}
static void add_target(MPRemoteCommand *command, BOOL enabled, MPRemoteCommandHandlerStatus (^handler)(MPRemoteCommandEvent *)) {
    command.enabled = enabled;
    if (enabled) [targets addObject:[command addTargetWithHandler:handler]];
}
static void install_targets(uint32_t commands) {
    remove_targets();
    targets = [NSMutableArray array];
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    BOOL play = (commands & BIT_PLAY) != 0, pause = (commands & BIT_PAUSE) != 0;
    add_target(center.playCommand, play, ^(MPRemoteCommandEvent *event) { (void)event; fire(BIT_PLAY, 0); return MPRemoteCommandHandlerStatusSuccess; });
    add_target(center.pauseCommand, pause, ^(MPRemoteCommandEvent *event) { (void)event; fire(BIT_PAUSE, 0); return MPRemoteCommandHandlerStatusSuccess; });
    add_target(center.togglePlayPauseCommand, play || pause, ^(MPRemoteCommandEvent *event) { (void)event; fire(BIT_TOGGLE, 0); return MPRemoteCommandHandlerStatusSuccess; });
    add_target(center.stopCommand, (commands & BIT_STOP) != 0, ^(MPRemoteCommandEvent *event) { (void)event; fire(BIT_STOP, 0); return MPRemoteCommandHandlerStatusSuccess; });
    add_target(center.nextTrackCommand, (commands & BIT_NEXT) != 0, ^(MPRemoteCommandEvent *event) { (void)event; fire(BIT_NEXT, 0); return MPRemoteCommandHandlerStatusSuccess; });
    add_target(center.previousTrackCommand, (commands & BIT_PREVIOUS) != 0, ^(MPRemoteCommandEvent *event) { (void)event; fire(BIT_PREVIOUS, 0); return MPRemoteCommandHandlerStatusSuccess; });
    add_target(center.changePlaybackPositionCommand, (commands & BIT_SEEK) != 0, ^(MPRemoteCommandEvent *event) {
        NSTimeInterval at = [(MPChangePlaybackPositionCommandEvent *)event positionTime];
        fire(BIT_SEEK, (int64_t)(at > 0 ? at * 1e6 : 0));
        return MPRemoteCommandHandlerStatusSuccess;
    });
}

/* Shows `info`, or with NULL clears what the system shows and stops
   commands. Returns 1. */
int znp_set(const ZnpInfo *info, ZnpDeliver deliver) {
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    if (!info) {
        deliver_command = NULL;
        remove_targets();
        center.nowPlayingInfo = nil;
        center.playbackState = MPNowPlayingPlaybackStateStopped;
        return 1;
    }
    deliver_command = deliver;
    NSMutableDictionary<NSString *, id> *values = [NSMutableDictionary dictionary];
    NSString *title = text(info->title), *artist = text(info->artist), *album = text(info->album);
    if (title) values[MPMediaItemPropertyTitle] = title;
    if (artist) values[MPMediaItemPropertyArtist] = artist;
    if (album) values[MPMediaItemPropertyAlbumTitle] = album;
    if (info->duration_us > 0) values[MPMediaItemPropertyPlaybackDuration] = @((double)info->duration_us / 1e6);
    values[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @((double)info->position_us / 1e6);
    double rate = info->rate > 0 ? info->rate : 1;
    values[MPNowPlayingInfoPropertyPlaybackRate] = @(info->state == 0 ? rate : 0.0);
    values[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @(rate);
    values[MPNowPlayingInfoPropertyMediaType] = @(MPNowPlayingInfoMediaTypeAudio);
    if (info->duration_us <= 0) values[MPNowPlayingInfoPropertyIsLiveStream] = @YES;
    if (info->artwork && info->artwork_len) {
        NSImage *image = [[NSImage alloc] initWithData:[NSData dataWithBytes:info->artwork length:info->artwork_len]];
        if (image) {
            values[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithBoundsSize:[image size] requestHandler:^NSImage *(CGSize size) {
                (void)size;
                return image;
            }];
        }
    }
    center.nowPlayingInfo = values;
    center.playbackState = info->state == 0 ? MPNowPlayingPlaybackStatePlaying : info->state == 1 ? MPNowPlayingPlaybackStatePaused : MPNowPlayingPlaybackStateStopped;
    install_targets(info->commands);
    return 1;
}

/* Test hook: a command through the same main-queue path as the handlers. */
void znp_simulate(uint32_t raw, int64_t position_us) { fire(raw, position_us); }
/* Test hook: the title the system shows, or "" when nothing shows. */
size_t znp_shown_title(char *out, size_t capacity) {
    NSString *title = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo[MPMediaItemPropertyTitle];
    const char *value = title ? [title UTF8String] : "";
    size_t len = strlen(value);
    if (capacity) {
        size_t copy = len < capacity - 1 ? len : capacity - 1;
        memcpy(out, value, copy);
        out[copy] = 0;
    }
    return len;
}
