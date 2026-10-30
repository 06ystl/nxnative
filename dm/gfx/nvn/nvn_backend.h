// Shared encoding helpers. Included after the renderer's device/queue globals.
// Metal 4 stays on its existing path; older systems use tracked Metal 3 resources.
#import "nvn_legacy.h"

static id backend_arguments(NSUInteger buffers, NSUInteger textures, NSUInteger samplers) {
    if (@available(iOS 26.0, macOS 26.0, *)) { if (g_metal4) {
        MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new];
        d.maxBufferBindCount = buffers; d.maxTextureBindCount = textures; d.maxSamplerStateBindCount = samplers;
        NSError *error = nil; id table = [g_dev newArgumentTableWithDescriptor:d error:&error];
        if (!table) MDIE("argument table: %s", error.localizedDescription.UTF8String);
        return table;
    } }
    return [NvLegacyArguments new];
}
static id backend_record_arguments(NSUInteger b, NSUInteger t, NSUInteger s) { return rec_table(backend_arguments(b, t, s)); }
static void backend_texture(id table, id<MTLTexture> texture, NSUInteger index) {
    if (@available(iOS 26.0, macOS 26.0, *)) { if (g_metal4) { [(id<MTL4ArgumentTable>)table setTexture:texture.gpuResourceID atIndex:index]; return; } }
    [(NvLegacyArguments *)table setTextureObject:texture atIndex:index];
}
static void backend_sampler(id table, id<MTLSamplerState> sampler, NSUInteger index) {
    if (@available(iOS 26.0, macOS 26.0, *)) { if (g_metal4) { [(id<MTL4ArgumentTable>)table setSamplerState:sampler.gpuResourceID atIndex:index]; return; } }
    [(NvLegacyArguments *)table setSamplerObject:sampler atIndex:index];
}
static void backend_set_arguments(id encoder, id table, MTLRenderStages stage) {
    if (@available(iOS 26.0, macOS 26.0, *)) { if (g_metal4) {
        if (stage) [(id<MTL4RenderCommandEncoder>)encoder setArgumentTable:table atStages:stage];
        else [(id<MTL4ComputeCommandEncoder>)encoder setArgumentTable:table];
        return;
    } }
    nvl_set_arguments(encoder, table, stage);
}
static MTLRenderPassDescriptor *backend_render_pass(void) {
    if (@available(iOS 26.0, macOS 26.0, *)) { if (g_metal4) return (id)[MTL4RenderPassDescriptor new]; }
    return [MTLRenderPassDescriptor renderPassDescriptor];
}
static id backend_command_buffer(void) {
    if (@available(iOS 26.0, macOS 26.0, *)) { if (g_metal4) return [g_dev newCommandBuffer]; }
    return [g_q commandBuffer];
}
static void backend_begin(id cb, id allocator) {
    if (@available(iOS 26.0, macOS 26.0, *)) { if (g_metal4) [cb beginCommandBufferWithAllocator:allocator]; }
}
static void backend_barrier(id encoder) {
    if (@available(iOS 26.0, macOS 26.0, *)) { if (g_metal4)
        [(id<MTL4CommandEncoder>)encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; }
}
// Both feedback APIs expose error and GPU timestamps. Serialize legacy callbacks
// on the same feedback queue so fence completion retains its existing ordering.
@protocol NvCommitFeedback <NSObject>
@property(readonly) NSError *error;
@property(readonly) CFTimeInterval GPUStartTime;
@property(readonly) CFTimeInterval GPUEndTime;
@end
static void backend_commit(id cb, NSArray *handlers, int role) {
    if (@available(iOS 26.0, macOS 26.0, *)) { if (g_metal4) {
        MTL4CommitOptions *o = [MTL4CommitOptions new];
        for (void (^handler)(id<NvCommitFeedback>) in handlers)
            [o addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { handler((id)feedback); }];
        [cb endCommandBuffer];
        if (role == 0) rec_commit(cb, o);
        else if (role == 1) rec_commit_upload(cb, o);
        else { id<MTL4CommandBuffer> buffers[] = {cb}; [g_q4 commit:buffers count:1 options:o]; }
        return;
    } }
    ubc_wait(ubc_head());
    [(id<MTLCommandBuffer>)cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        dispatch_async(g_feedback_q, ^{ for (void (^handler)(id<NvCommitFeedback>) in handlers) handler((id)completed); });
    }];
    [(id<MTLCommandBuffer>)cb commit];
}
