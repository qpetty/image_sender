//
//  GStreamerBridge.h
//  Image_sender
//
//  Created by Quinton on 12/9/25.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

@interface GStreamerBridge : NSObject

+ (instancetype)shared;

- (BOOL)startPipelineWithHost:(NSString *)host port:(int)port;
- (void)stopPipeline;

- (void)pushH264Data:(NSData *)naluData
          isKeyframe:(BOOL)isKeyframe
    presentationTime:(CMTime)presentationTime;

@end
