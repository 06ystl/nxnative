#import "nvn_legacy.h"
#import <objc/runtime.h>
#import <os/lock.h>

// Registration follows the renderer's existing deferred resource lifetime.
// Keep GPU addresses sorted so each root binding costs a binary search.
static NSMutableArray<id<MTLBuffer>> *buffers;
static os_unfair_lock buffer_lock = OS_UNFAIR_LOCK_INIT;
static NSUInteger lower_bound(uint64_t address) {
    NSUInteger lo = 0, hi = buffers.count;
    while (lo < hi) { NSUInteger mid = lo + (hi - lo) / 2;
        if (buffers[mid].gpuAddress < address) lo = mid + 1; else hi = mid; }
    return lo;
}
void nvl_buffer_add(id<MTLResource> resource) {
    if (![resource conformsToProtocol:@protocol(MTLBuffer)]) return;
    id<MTLBuffer> buffer = (id)resource;
    os_unfair_lock_lock(&buffer_lock);
    if (!buffers) buffers = [NSMutableArray array];
    NSUInteger i = lower_bound(buffer.gpuAddress);
    NSUInteger end = i;
    while (end < buffers.count && buffers[end].gpuAddress == buffer.gpuAddress) {
        if (buffers[end] == buffer) { os_unfair_lock_unlock(&buffer_lock); return; }
        end++;
    }
    [buffers insertObject:buffer atIndex:i];
    os_unfair_lock_unlock(&buffer_lock);
}
void nvl_buffer_remove(id<MTLResource> resource) {
    if (![resource conformsToProtocol:@protocol(MTLBuffer)]) return;
    os_unfair_lock_lock(&buffer_lock);
    NSUInteger i = lower_bound(((id<MTLBuffer>)resource).gpuAddress);
    while (i < buffers.count && buffers[i].gpuAddress == ((id<MTLBuffer>)resource).gpuAddress) {
        if (buffers[i] == resource) { [buffers removeObjectAtIndex:i]; break; }
        i++;
    }
    os_unfair_lock_unlock(&buffer_lock);
}
id<MTLBuffer> nvl_buffer_at(uint64_t address, NSUInteger length, NSUInteger *offset) {
    os_unfair_lock_lock(&buffer_lock);
    NSUInteger i = lower_bound(address);
    while (i < buffers.count && buffers[i].gpuAddress == address) i++;
    id<MTLBuffer> buffer = nil;
    // No-copy pools can alias. A shorter alias must not hide a larger buffer
    // covering the requested range. The usual non-overlapping case hits first.
    while (i) {
        id<MTLBuffer> candidate = buffers[--i];
        uint64_t start = candidate.gpuAddress, size = candidate.length;
        if (address >= start && address - start <= size && length <= size - (address - start)) {
            buffer = candidate; if (offset) *offset = address - start; break;
        }
    }
    os_unfair_lock_unlock(&buffer_lock);
    return buffer;
}

@implementation NvLegacyArguments {
@public
    id<MTLBuffer> _buffers[31]; NSUInteger _offsets[31]; uint32_t _bufferMask;
    id<MTLTexture> _textures[32]; uint32_t _textureMask;
    id<MTLSamplerState> _samplers[16]; uint16_t _samplerMask;
}
- (void)setAddress:(uint64_t)address atIndex:(NSUInteger)index {
    NSCAssert(index < 31, @"buffer binding out of range");
    NSUInteger offset = 0;
    id<MTLBuffer> buffer = address ? nvl_buffer_at(address, 1, &offset) : nil;
    if (address && !buffer) { fprintf(stderr, "[dm] [nvn-mtl] FATAL unregistered Metal 3 buffer address %#llx\n", (unsigned long long)address); abort(); }
    _buffers[index] = buffer; _offsets[index] = offset; _bufferMask |= 1u << index;
}
- (void)setTextureObject:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    NSCAssert(index < 32, @"texture binding out of range");
    _textures[index] = texture; _textureMask |= 1u << index;
}
- (void)setSamplerObject:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    NSCAssert(index < 16, @"sampler binding out of range");
    _samplers[index] = sampler; _samplerMask |= 1u << index;
}
@end

typedef struct {
    __unsafe_unretained id<MTLBuffer> buffers[31]; NSUInteger offsets[31]; uint32_t bufferMask;
    __unsafe_unretained id<MTLTexture> textures[32]; uint32_t textureMask;
    __unsafe_unretained id<MTLSamplerState> samplers[16]; uint16_t samplerMask;
} NvLegacyApplied;
@interface NvLegacyBindings : NSObject {
@public NvLegacyArguments *vertex, *fragment, *compute;
    NvLegacyApplied applied[3]; CFMutableDictionaryRef resources;
}
@end
@implementation NvLegacyBindings
- (instancetype)init { if ((self = [super init])) resources = CFDictionaryCreateMutable(NULL, 0, NULL, NULL); return self; }
- (void)dealloc { CFRelease(resources); }
@end
static char bindings_key;
static NvLegacyBindings *bindings(id encoder) {
    NvLegacyBindings *b = objc_getAssociatedObject(encoder, &bindings_key);
    if (!b) { b = [NvLegacyBindings new]; objc_setAssociatedObject(encoder, &bindings_key, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return b;
}
void nvl_set_arguments(id encoder, NvLegacyArguments *table, MTLRenderStages stage) {
    NvLegacyBindings *b = bindings(encoder);
    if (stage == MTLRenderStageVertex) b->vertex = table;
    else if (stage == MTLRenderStageFragment) b->fragment = table;
    else b->compute = table;
}
static void apply(id encoder, NvLegacyArguments *table, MTLRenderStages stage, NvLegacyApplied *last) {
    if (!table) return;
    id<MTLRenderCommandEncoder> r = encoder; id<MTLComputeCommandEncoder> c = encoder;
    uint32_t mask = table->_bufferMask | last->bufferMask;
    while (mask) { unsigned i = __builtin_ctz(mask); uint32_t bit = 1u << i; mask &= mask - 1;
        id<MTLBuffer> value = table->_bufferMask & bit ? table->_buffers[i] : nil;
        NSUInteger offset = value ? table->_offsets[i] : 0;
        if ((last->bufferMask & bit) && last->buffers[i] == value && last->offsets[i] == offset) continue;
        if (stage == MTLRenderStageVertex) [r setVertexBuffer:value offset:offset atIndex:i];
        else if (stage == MTLRenderStageFragment) [r setFragmentBuffer:value offset:offset atIndex:i];
        else [c setBuffer:value offset:offset atIndex:i];
        last->buffers[i] = value; last->offsets[i] = offset;
    }
    last->bufferMask = table->_bufferMask;
    mask = table->_textureMask | last->textureMask;
    while (mask) { unsigned i = __builtin_ctz(mask); uint32_t bit = 1u << i; mask &= mask - 1;
        id<MTLTexture> value = table->_textureMask & bit ? table->_textures[i] : nil;
        if ((last->textureMask & bit) && last->textures[i] == value) continue;
        if (stage == MTLRenderStageVertex) [r setVertexTexture:value atIndex:i];
        else if (stage == MTLRenderStageFragment) [r setFragmentTexture:value atIndex:i];
        else [c setTexture:value atIndex:i];
        last->textures[i] = value;
    }
    last->textureMask = table->_textureMask;
    mask = table->_samplerMask | last->samplerMask;
    while (mask) { unsigned i = __builtin_ctz(mask); uint32_t bit = 1u << i; mask &= mask - 1;
        id<MTLSamplerState> value = table->_samplerMask & bit ? table->_samplers[i] : nil;
        if ((last->samplerMask & bit) && last->samplers[i] == value) continue;
        if (stage == MTLRenderStageVertex) [r setVertexSamplerState:value atIndex:i];
        else if (stage == MTLRenderStageFragment) [r setFragmentSamplerState:value atIndex:i];
        else [c setSamplerState:value atIndex:i];
        last->samplers[i] = value;
    }
    last->samplerMask = table->_samplerMask;
}
void nvl_apply_arguments(id encoder) {
    NvLegacyBindings *b = objc_getAssociatedObject(encoder, &bindings_key);
    if (!b) return;
    apply(encoder, b->vertex, MTLRenderStageVertex, &b->applied[0]);
    apply(encoder, b->fragment, MTLRenderStageFragment, &b->applied[1]);
    apply(encoder, b->compute, 0, &b->applied[2]);
}
void nvl_use_resource(id encoder, id resource, MTLResourceUsage usage, MTLRenderStages stage) {
    if (!resource) return;
    NvLegacyBindings *b = bindings(encoder);
    const void *key = (__bridge const void *)resource;
    uintptr_t old = (uintptr_t)CFDictionaryGetValue(b->resources, key);
    uintptr_t flags = (uintptr_t)usage << (stage == MTLRenderStageVertex ? 0 : stage == MTLRenderStageFragment ? 3 : 6);
    if ((old & flags) == flags || (old & 512)) return;
    // Samplers have resource IDs but are not MTLResource allocations.
    if (![resource conformsToProtocol:@protocol(MTLResource)]) { CFDictionarySetValue(b->resources, key, (const void *)512); return; }
    CFDictionarySetValue(b->resources, key, (const void *)(old | flags));
    if (stage) [(id<MTLRenderCommandEncoder>)encoder useResource:resource usage:usage stages:stage];
    else [(id<MTLComputeCommandEncoder>)encoder useResource:resource usage:usage];
}
