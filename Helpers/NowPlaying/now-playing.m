// Prints what's playing on this Mac as one line of JSON per second.
//
// macOS only answers these questions for programs it trusts, and a plain app gets nothing back.
// /usr/bin/perl is one of those programs, so the Mac app starts it and has it load this library.
// When the Mac app goes away, the next write fails and the signal from that ends this process.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfo)(dispatch_queue_t, void (^)(NSDictionary *));

void i7_now_playing(void) {
    void *framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    GetInfo getInfo = (GetInfo)dlsym(framework, "MRMediaRemoteGetNowPlayingInfo");
    if (!getInfo) return;

    __block NSString *lastArtwork = nil;
    while (1) {
        @autoreleasepool {
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            getInfo(dispatch_get_global_queue(0, 0), ^(NSDictionary *info) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
                out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
                out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
                out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;

                // The reported position was true at the reported moment, so carry it forward to now.
                double elapsed = [info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
                NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                if (stamp) elapsed += -[stamp timeIntervalSinceNow] * [out[@"rate"] doubleValue];
                out[@"elapsed"] = @(elapsed);

                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                NSString *artID = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
                if (!artID && art) artID = [NSString stringWithFormat:@"%lu", (unsigned long)art.hash];
                if (art && artID && ![artID isEqual:lastArtwork]) {
                    lastArtwork = artID;
                    out[@"art"] = [art base64EncodedStringWithOptions:0];
                }

                NSData *line = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                if (line) {
                    fwrite(line.bytes, 1, line.length, stdout);
                    fputc('\n', stdout);
                    fflush(stdout);
                }
                dispatch_semaphore_signal(done);
            });
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        }
        sleep(1);
    }
}
