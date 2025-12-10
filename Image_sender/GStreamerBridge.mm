//
//  GStreamerBridge.mm
//  Image_sender
//
//  Created by Quinton on 12/9/25.
//

#import "GStreamerBridge.h"
#import <GStreamer/gst/gst.h>
#import <GStreamer/gst/app/gstappsrc.h>
#import <CoreMedia/CoreMedia.h>
#import <GStreamer/gst/video/video.h>

@interface GStreamerBridge ()
@property (nonatomic, assign) GstElement *pipeline;
@property (nonatomic, assign) GstAppSrc *appSrc;
@property (nonatomic, assign) guint64 frameCount;
@end

@implementation GStreamerBridge

+ (instancetype)shared {
    static GStreamerBridge *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
        // Initialize GStreamer here once
        gst_init(NULL, NULL);
    });
    return sharedInstance;
}

- (BOOL)startPipelineWithHost:(NSString *)host port:(int)port {
    if (self.pipeline) {
        return YES; // Already running
    }
    
    // Construct the pipeline string
    NSString *pipelineString = [NSString stringWithFormat:
        @"appsrc name=video_source format=time is-live=true do-timestamp=true ! "
         "video/x-h264,alignment=nal ! "
         "h264parse config-interval=1 ! "
         "mpegtsmux alignment=1 ! "
         "tcpclientsink host=%@ port=%d sync=false nodelay=true",
        host, port];
        
    GError *error = NULL;
    self.pipeline = gst_parse_launch([pipelineString UTF8String], &error);

    if (!self.pipeline) {
        NSLog(@"GStreamer pipeline error: %@", [NSString stringWithUTF8String:error->message]);
        g_error_free(error);
        return NO;
    }

    self.appSrc = (GstAppSrc *)gst_bin_get_by_name(GST_BIN(self.pipeline), "video_source");
    if (!self.appSrc) {
        NSLog(@"Failed to find appsrc element.");
        return NO;
    }
    
    // Set low-latency properties on appsrc
    gst_app_src_set_caps(self.appSrc, gst_caps_from_string("video/x-h264, alignment=nalu"));
    // Mark source as live using the property (older GStreamer headers lack gst_app_src_set_is_live)
    g_object_set(self.appSrc, "is-live", TRUE, NULL);
    // Setting max-latency helps drop frames if the network bottlenecks
    // gst_app_src_set_max_bytes(self.appSrc, 1024 * 1024 * 5); // 5MB buffer limit

    gst_element_set_state(self.pipeline, GST_STATE_PLAYING);
    self.frameCount = 0;
    
    return YES;
}

- (void)stopPipeline {
    if (self.pipeline) {
        // Send EOS event to flush the stream gracefully
        gst_app_src_end_of_stream(self.appSrc);
        
        // Stop the pipeline
        gst_element_set_state(self.pipeline, GST_STATE_NULL);
        gst_object_unref(self.pipeline);
        self.pipeline = NULL;
        self.appSrc = NULL;
    }
}

- (void)pushH264Data:(NSData *)naluData
          isKeyframe:(BOOL)isKeyframe
    presentationTime:(CMTime)presentationTime {
    
    if (!self.appSrc || !self.pipeline || GST_STATE(self.pipeline) != GST_STATE_PLAYING) {
        return;
    }
    
    // 1. Create a GstBuffer
    GstBuffer *buffer = gst_buffer_new_allocate(NULL, (gsize)naluData.length, NULL);
    
    // 2. Copy the H.264 NALU data into the GstBuffer
    // NOTE: For ultimate performance, you would use gst_buffer_new_wrapped_full
    // to wrap the CVPixelBuffer memory directly, but since VideoToolbox output
    // is already a fragmented CMBlockBuffer/NSData, a copy is often needed anyway,
    // so this is the simplest approach.
    gst_buffer_fill(buffer, 0, naluData.bytes, naluData.length);

    // 3. Set properties (Timestamp and Flags)
    
    // Convert CMTime to GStreamer's nanoseconds (GST_TIME_AS_USECONDS * 1000)
    // CMTime is typically 64-bit value / timescale.
    guint64 pts_nanos = gst_util_uint64_scale(presentationTime.value, GST_SECOND, presentationTime.timescale);
    GST_BUFFER_PTS(buffer) = pts_nanos;
    
    // Set duration (assuming 30fps)
    GST_BUFFER_DURATION(buffer) = GST_SECOND / 30;
    
    // Set Keyframe flag (I-frame)
    // Older GStreamer uses DELTA_UNIT to signal non-keyframes
    if (isKeyframe) {
        GST_BUFFER_FLAG_UNSET(buffer, GST_BUFFER_FLAG_DELTA_UNIT);
    } else {
        GST_BUFFER_FLAG_SET(buffer, GST_BUFFER_FLAG_DELTA_UNIT);
    }
    
    // 4. Push the buffer to the pipeline
    GstFlowReturn ret = gst_app_src_push_buffer(self.appSrc, buffer);
    
    if (ret != GST_FLOW_OK) {
        NSLog(@"GStreamer appsrc push failed: %d", ret);
        // On failure, the buffer is not consumed, so we must unref it.
        gst_buffer_unref(buffer);
    } else {
        self.frameCount++;
    }
}

@end
