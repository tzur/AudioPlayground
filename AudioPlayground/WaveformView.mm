// Copyright (c) 2017 Lightricks. All rights reserved.
// Created by Zur Tene.

#import "WaveformView.h"

#import <algorithm>

#import <vector>

NS_ASSUME_NONNULL_BEGIN

@interface WaveformView ()

@property (readonly, nonatomic) std::vector<float> data;

@property (readonly, nonatomic) size_t size;

@end

bool compare(const CGPoint &a , const CGPoint &b){
  return a.y < b.y;
}

@implementation WaveformView

- (void)updateData:(float *)data size:(size_t)size {
  if (!round(*data)) {
    return;
  }
  _data = std::vector<float>(data, data + size);
  [self setNeedsLayout];
  [self layoutIfNeeded];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
  if (self.data.empty()) {
    return;
  }
  std::vector<CGPoint> points;
  static const size_t sampleSize = 150;
  size_t jumper = self.data.size() / sampleSize;
  size_t strideX = rect.size.width / sampleSize;
  size_t currentStide = 0;
  for (size_t i = 0; i < self.data.size(); i+= jumper) {
    points.push_back(CGPointMake(currentStide, self.data[i]));
    currentStide += strideX;
  }
  auto maxIter = std::max_element(points.begin(), points.end(), compare);
  double maxY = (maxIter)->y;
  std::vector<CGPoint>normalizedPoints;
  for (auto point : points) {
    normalizedPoints.push_back(CGPointMake(point.x, point.y / maxY * rect.size.height));
  }

  CGMutablePathRef path = CGPathCreateMutable();
  CGPathAddLines(path, NULL, normalizedPoints.data(), normalizedPoints.size());

  CGMutablePathRef waveformPath = CGPathCreateMutable();
//  CGAffineTransform upperPathTransform = EVDWaveformTransformMake(floor(rect.size.height / 2));
//  CGPathAddPath(waveformPath, &upperPathTransform, path);
  CGContextRef context = UIGraphicsGetCurrentContext();
  CGContextAddPath(context, path);
  CGContextSetStrokeColorWithColor(context, [UIColor blueColor].CGColor);
  CGContextStrokePath(context);

  CGPathRelease(path);
  CGPathRelease(waveformPath);
}

static CGAffineTransform EVDWaveformTransformMake(CGFloat height) {
  CGAffineTransform transform = CGAffineTransformMakeTranslation(0, height);
  return CGAffineTransformScale(transform, 1.0, -height);
}

@end

NS_ASSUME_NONNULL_END
