// Metal 3 bindings for the shared NVN renderer (iOS 17+).
#pragma once
#import <Metal/Metal.h>

void nvl_buffer_add(id<MTLResource> resource);
void nvl_buffer_remove(id<MTLResource> resource);
id<MTLBuffer> nvl_buffer_at(uint64_t address, NSUInteger length, NSUInteger *offset);

@interface NvLegacyArguments : NSObject
- (void)setAddress:(uint64_t)address atIndex:(NSUInteger)index;
- (void)setTextureObject:(id<MTLTexture>)texture atIndex:(NSUInteger)index;
- (void)setSamplerObject:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index;
@end
void nvl_set_arguments(id encoder, NvLegacyArguments *table, MTLRenderStages stage);
void nvl_apply_arguments(id encoder);
void nvl_use_resource(id encoder, id resource, MTLResourceUsage usage, MTLRenderStages stage);
