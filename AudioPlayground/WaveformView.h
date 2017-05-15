// Copyright (c) 2017 Lightricks. All rights reserved.
// Created by Zur Tene.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WaveformView : UIView

- (void)updateData:(float *)data size:(size_t)size;

@end

NS_ASSUME_NONNULL_END
