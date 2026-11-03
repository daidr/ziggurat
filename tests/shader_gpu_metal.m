/* Runs translated shader programs on Metal one invocation per pixel, for
   the GPU/CPU parity check. The library is compiled without fast math, as
   the renderer compiles it. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;

int zsm_init(char *log, size_t log_len) {
    if (device) return 0;
    device = MTLCreateSystemDefaultDevice();
    if (!device) {
        snprintf(log, log_len, "no Metal device");
        return 1;
    }
    queue = [device newCommandQueue];
    return queue ? 0 : 1;
}

/* Run the kernel `zs_test` of `source` over width x height threads; it
   writes result and status (float4 each, row-major); the words fill
   buffer 0. */
int zsm_run(const char *source, const uint32_t *words, uint32_t word_count, uint32_t width, uint32_t height, float *result, float *status, char *log, size_t log_len) {
    @autoreleasepool {
        MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        options.fastMathEnabled = NO;
#pragma clang diagnostic pop
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:source] options:options error:&error];
        if (!library) {
            snprintf(log, log_len, "%s", [[error localizedDescription] UTF8String]);
            return 2;
        }
        id<MTLFunction> function = [library newFunctionWithName:@"zs_test"];
        id<MTLComputePipelineState> pipeline = function ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
        if (!pipeline) {
            snprintf(log, log_len, "%s", error ? [[error localizedDescription] UTF8String] : "no zs_test");
            return 3;
        }
        uint32_t padded[4096] = {0};
        if (word_count > 4096) return 4;
        memcpy(padded, words, word_count * sizeof(uint32_t));
        size_t vectors = (word_count + 3) / 4;
        if (vectors == 0) vectors = 1;
        size_t bytes = (size_t)width * height * 16;
        id<MTLBuffer> input = [device newBufferWithBytes:padded length:vectors * 16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> results = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> statuses = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> commands = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:input offset:0 atIndex:0];
        [encoder setBuffer:results offset:0 atIndex:1];
        [encoder setBuffer:statuses offset:0 atIndex:2];
        [encoder setBytes:&width length:sizeof(width) atIndex:3];
        [encoder dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [encoder endEncoding];
        [commands commit];
        [commands waitUntilCompleted];
        if (commands.status != MTLCommandBufferStatusCompleted) {
            snprintf(log, log_len, "command buffer failed");
            return 5;
        }
        memcpy(result, results.contents, bytes);
        memcpy(status, statuses.contents, bytes);
    }
    return 0;
}
