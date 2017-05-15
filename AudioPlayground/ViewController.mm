//
//  ViewController.m
//  AudioPlayground
//
//  Created by Zur Tene on 14/05/2017.
//  Copyright © 2017 zur tene. All rights reserved.
//

#import "ViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>


#import "WaveformView.h"
#import <algorithm>

#import "ProcessorContext.h"

@interface ViewController ()

@property (readonly, nonatomic) UIButton *play;

@property (readonly, nonatomic) UIButton *pause;

@property (readonly, nonatomic) UIButton *increaseGain;

@property (readonly, nonatomic) UIButton *decreaseGain;

@property (readonly, nonatomic) AVPlayer *player;

@property (readonly, nonatomic) AVAudioEngine *engine;

@property (readonly, nonatomic) AVAudioPlayerNode *inputNode;

@property (nonatomic) NSInteger firstGain;

@property (nonatomic) NSInteger secondGain;

@property (nonatomic) NSInteger thirdGain;

@property (nonatomic) NSInteger fourthGain;

@property (nonatomic) AudioUnit privateAudioUnit;

@property (readonly, nonatomic) UIButton *first;

@property (readonly, nonatomic) UIButton *second;

@property (readonly, nonatomic) UIButton *third;

@property (readonly, nonatomic) UIButton *fourth;

@property (nonatomic) UInt32 frequency;

@property (readonly, nonatomic) UILabel *firstLabel;

@property (readonly, nonatomic) UILabel *secondLabel;

@property (readonly, nonatomic) UILabel *thirdLabel;

@property (readonly, nonatomic) UILabel *fourthLabel;

@property (readonly, nonatomic) WaveformView *waveformView;

@property (readonly, nonatomic) WaveformView *outputWaveformView;

@end

@implementation ViewController

#pragma mark -
#pragma mark Tap
#pragma mark -

static FFTSetup setup;

static WaveformView *sWaveformView;

static WaveformView *sOutputWaveformView;

typedef struct AVAudioTapProcessorContext {
  Boolean supportedTapProcessingFormat;
  Boolean isNonInterleaved;
  Float64 sampleRate;
  AudioUnit audioUnit;
  Float64 sampleCount;
  float leftChannelVolume;
  float rightChannelVolume;
  void *self;
} AVAudioTapProcessorContext;

static void tap_InitCallback(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut)
{
  AVAudioTapProcessorContext *context = (AVAudioTapProcessorContext *)calloc(1, sizeof(AVAudioTapProcessorContext));

  // Initialize MTAudioProcessingTap context.
  context->supportedTapProcessingFormat = false;
  context->isNonInterleaved = false;
  context->sampleRate = NAN;
  context->audioUnit = NULL;
  context->sampleCount = 0.0f;
  context->leftChannelVolume = 0.0f;
  context->rightChannelVolume = 0.0f;
  context->self = clientInfo;

  *tapStorageOut = context;
}

static void tap_FinalizeCallback(MTAudioProcessingTapRef tap)
{
  AVAudioTapProcessorContext *context = (AVAudioTapProcessorContext *)MTAudioProcessingTapGetStorage(tap);

  // Clear MTAudioProcessingTap context.
  context->self = NULL;

  free(context);
}

static void tap_PrepareCallback(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *processingFormat)
{
  NSLog(@"format id: %d ", processingFormat->mFormatID);
  NSLog(@"flags %u ", (unsigned)processingFormat->mFormatFlags);
  NSLog(@"frame %u", processingFormat->mChannelsPerFrame);
  NSLog(@"prepare");
  AVAudioTapProcessorContext *context = (AVAudioTapProcessorContext *)MTAudioProcessingTapGetStorage(tap);

  // Store sample rate for -setCenterFrequency:.
  context->sampleRate = processingFormat->mSampleRate;

  /* Verify processing format (this is not needed for Audio Unit, but for RMS calculation). */

  context->supportedTapProcessingFormat = true;

  if (processingFormat->mFormatID != kAudioFormatLinearPCM)
  {
    NSLog(@"Unsupported audio format ID for audioProcessingTap. LinearPCM only.");
    context->supportedTapProcessingFormat = false;
  }

  if (!(processingFormat->mFormatFlags & kAudioFormatFlagIsFloat))
  {
    NSLog(@"Unsupported audio format flag for audioProcessingTap. Float only.");
    context->supportedTapProcessingFormat = false;
  }

  if (processingFormat->mFormatFlags & kAudioFormatFlagIsNonInterleaved)
  {
    context->isNonInterleaved = true;
  }

  /* Create bandpass filter Audio Unit */

  AudioUnit audioUnit;
  AudioComponentDescription audioComponentDescription;
  audioComponentDescription.componentType = kAudioUnitType_Effect;
  audioComponentDescription.componentSubType = kAudioUnitSubType_NBandEQ;
  audioComponentDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
  audioComponentDescription.componentFlags = 0;
  audioComponentDescription.componentFlagsMask = 0;

  AudioComponent audioComponent = AudioComponentFindNext(NULL, &audioComponentDescription);
  if (audioComponent)
  {
    if (noErr == AudioComponentInstanceNew(audioComponent, &audioUnit))
    {
      OSStatus status = noErr;

      // Set audio unit input/output stream format to processing format.
      if (noErr == status)
      {
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, processingFormat, sizeof(AudioStreamBasicDescription));
      }
      if (noErr == status)
      {
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, processingFormat, sizeof(AudioStreamBasicDescription));
      }

      // Set audio unit render callback.
      if (noErr == status)
      {
        AURenderCallbackStruct renderCallbackStruct;
        renderCallbackStruct.inputProc = AU_RenderCallback;
        renderCallbackStruct.inputProcRefCon = (void *)tap;
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallbackStruct, sizeof(AURenderCallbackStruct));
      }

      // Set audio unit maximum frames per slice to max frames.
      if (noErr == status)
      {
        UInt32 maximumFramesPerSlice = maxFrames;
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFramesPerSlice, (UInt32)sizeof(UInt32));
      }

      NSArray *eqFrequencies = @[@32, @250, @500, @1000, @16000, @20000];
      NSArray *bypass = @[@0, @0, @0, @0, @0, @0];

      size_t bandsCount = eqFrequencies.count;
      AudioUnitSetProperty(audioUnit,
                           kAUNBandEQProperty_NumberOfBands,
                           kAudioUnitScope_Global,
                           0,
                           &bandsCount,
                           sizeof(bandsCount));

      for (UInt32 i = 0; i < bandsCount; ++i) {
        AudioUnitSetParameter(audioUnit,
                              kAUNBandEQParam_Frequency + i,
                              kAudioUnitScope_Global,
                              0,
                              (AudioUnitParameterValue)[eqFrequencies[i] floatValue],
                              0);

        AudioUnitSetParameter(audioUnit,
                              kAUNBandEQParam_BypassBand + i,
                              kAudioUnitScope_Global,
                              0,
                              (AudioUnitParameterValue)[bypass[0] floatValue],
                              0);
      }

      AudioUnitSetParameter(audioUnit, kAUNBandEQParam_Bandwidth + (UInt32)3, kAudioUnitScope_Global, 0, (AudioUnitParameterValue)0.1, 0);



      // Initialize audio unit.
      if (noErr == status)
      {
        status = AudioUnitInitialize(audioUnit);
      }

      if (noErr != status)
      {
        AudioComponentInstanceDispose(audioUnit);
        audioUnit = NULL;
      }


      context->audioUnit = audioUnit;
    }
  }
}

static void tap_UnprepareCallback(MTAudioProcessingTapRef tap) {
  AVAudioTapProcessorContext *context = (AVAudioTapProcessorContext *)MTAudioProcessingTapGetStorage(tap);

  /* Release bandpass filter Audio Unit */
  NSLog(@"hjere");
  if (context->audioUnit)
  {
    AudioUnitUninitialize(context->audioUnit);
    AudioComponentInstanceDispose(context->audioUnit);
    context->audioUnit = NULL;
  }
}

static void tap_ProcessCallback(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                                MTAudioProcessingTapFlags flags,
                                AudioBufferList *bufferListInOut,
                                CMItemCount *numberFramesOut,
                                MTAudioProcessingTapFlags *flagsOut) {
  AVAudioTapProcessorContext *context = (AVAudioTapProcessorContext *)MTAudioProcessingTapGetStorage(tap);

  OSStatus status;

  // Skip processing when format not supported.
  if (!context->supportedTapProcessingFormat)
  {
    NSLog(@"Unsupported tap processing format.");
    return;
  }

  NSLog(@"process");
  ViewController *self = ((__bridge ViewController *)context->self);
  self.privateAudioUnit = context->audioUnit;

  if (1)
  {
    // Apply bandpass filter Audio Unit.
    AudioUnit audioUnit = context->audioUnit;
    if (audioUnit)
    {
      AudioTimeStamp audioTimeStamp;
      audioTimeStamp.mSampleTime = context->sampleCount;
      audioTimeStamp.mFlags = kAudioTimeStampSampleTimeValid;

      status = AudioUnitRender(context->audioUnit, 0, &audioTimeStamp, 0, (UInt32)numberFrames,
                               bufferListInOut);
      float *dogs =
          DemonstratevDSP_fft_zrip(setup, (float *)bufferListInOut->mBuffers[0].mData,
                                   numberFrames);
      UpdateOutputViewWithData(dogs, numberFrames / 2);
      if (noErr != status)
      {
        NSLog(@"AudioUnitRender(): %d", (int)status);
        return;
      }

      // Increment sample count for audio unit.
      context->sampleCount += numberFrames;

      // Set number of frames out.
      *numberFramesOut = numberFrames;
    }
  }
  else
  {
    // Get actual audio buffers from MTAudioProcessingTap (AudioUnitRender() will fill bufferListInOut otherwise).
    status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
    if (noErr != status)
    {
      NSLog(@"MTAudioProcessingTapGetSourceAudio: %d", (int)status);
      return;
    }
  }
}

#pragma mark - Audio Unit Callbacks

OSStatus AU_RenderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                           const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                           UInt32 inNumberFrames, AudioBufferList *ioData) {

  OSStatus status =  MTAudioProcessingTapGetSourceAudio((MTAudioProcessingTapRef)inRefCon, inNumberFrames, ioData, NULL, NULL, NULL);

  float *dogs =
      DemonstratevDSP_fft_zrip(setup, (float *)ioData->mBuffers[0].mData, inNumberFrames);
  UpdateViewWithData(dogs, inNumberFrames / 2);
  return status;
}

#pragma mark -
#pragma mark Video View
#pragma mark -

- (void)viewDidLoad {
  [super viewDidLoad];

  [self setupVideoView];
  [self setupWaveformView];
  [self setupButtons];

  setup = vDSP_create_fftsetup(std::ceil(std::log2(4096)), FFT_RADIX2);
  if (setup == NULL)
  {
    fprintf(stderr, "Error, vDSP_create_fftsetup failed.\n");
    exit (EXIT_FAILURE);
  }
}

- (void)setupWaveformView {
  _waveformView = [[WaveformView alloc] initWithFrame:CGRectMake(0, 350, 800, 200)];
  self.waveformView.backgroundColor = [UIColor whiteColor];
  sWaveformView = self.waveformView;
  [self.view addSubview:sWaveformView];

  _outputWaveformView = [[WaveformView alloc] initWithFrame:CGRectMake(0, 100, 800, 200)];
  self.outputWaveformView.backgroundColor = [UIColor whiteColor];
  sOutputWaveformView = self.outputWaveformView;
  [self.view addSubview:sOutputWaveformView];
}

static void UpdateOutputViewWithData(float *data, size_t size) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [sOutputWaveformView updateData:data size:size];
    free(data);
  });
};

static void UpdateViewWithData(float *data, size_t size) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [sWaveformView updateData:data size:size];
     free(data);
  });
};

- (void)setupVideoView {
  AVPlayerLayer *playerLayer = [[AVPlayerLayer alloc] init];
  playerLayer.frame = self.view.bounds;

  NSURL *assetURL = [[NSBundle mainBundle] URLForResource:@"dana" withExtension:@"mp4"];
  AVAsset *asset = [AVAsset assetWithURL:assetURL];
  AVMutableComposition *composition = [[AVMutableComposition alloc] init];

  for (AVAssetTrack *track in asset.tracks) {
    [composition insertTimeRange:track.timeRange ofAsset:asset atTime:kCMTimeZero error:nil];
  }

  AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
  NSMutableArray *inputParameters = [NSMutableArray array];
  for (AVAssetTrack *track in [asset tracksWithMediaType:AVMediaTypeAudio]) {
    AVMutableAudioMixInputParameters *input = [AVMutableAudioMixInputParameters audioMixInputParameters];
    input.trackID = track.trackID;
    MTAudioProcessingTapRef tap;
    MTAudioProcessingTapCallbacks callbacks;
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.clientInfo = (__bridge void *)(self);
    callbacks.init = tap_InitCallback;
    callbacks.prepare = tap_PrepareCallback;
    callbacks.process = tap_ProcessCallback;
    callbacks.unprepare = tap_UnprepareCallback;
    callbacks.finalize = tap_FinalizeCallback;
    OSStatus err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                              kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
    if (err || !tap) {
      NSLog(@"Unable to create the Audio Processing Tap");
    }
    assert(tap);
    input.audioTapProcessor = tap;
    [inputParameters addObject:input];
  }

  audioMix.inputParameters = inputParameters;
  AVPlayerItem *playerItem = [[AVPlayerItem alloc] initWithAsset:composition];
  playerItem.audioMix = audioMix;
  _player = [[AVPlayer alloc] initWithPlayerItem:playerItem];
  playerLayer.player = self.player;
  [self.view.layer addSublayer:playerLayer];
}

- (void)setupButtons {
  self.frequency = 900;
  _play = [[UIButton alloc] initWithFrame:CGRectMake(15, self.view.frame.size.height - 30, 80, 30)];
  _pause = [[UIButton alloc] initWithFrame:CGRectMake(100, self.view.frame.size.height - 30, 80, 30)];
  _increaseGain = [[UIButton alloc] initWithFrame:CGRectMake(195, self.view.frame.size.height - 30, 80, 30)];
  _decreaseGain = [[UIButton alloc] initWithFrame:CGRectMake(290, self.view.frame.size.height - 30, 80, 30)];
  _first = [[UIButton alloc] initWithFrame:CGRectMake(10, 10, 80, 30)];
  _firstLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 50, 80, 30)];
  _second = [[UIButton alloc] initWithFrame:CGRectMake(100, 10, 80, 30)];
  _secondLabel = [[UILabel alloc] initWithFrame:CGRectMake(100, 50, 80, 30)];
  _third = [[UIButton alloc] initWithFrame:CGRectMake(190, 10, 80, 30)];
  _thirdLabel = [[UILabel alloc] initWithFrame:CGRectMake(190, 50, 80, 30)];
  _fourth = [[UIButton alloc] initWithFrame:CGRectMake(280, 10, 80, 30)];
  _fourthLabel = [[UILabel alloc] initWithFrame:CGRectMake(280, 50, 80, 30)];

  self.first.backgroundColor = [UIColor whiteColor];
  [self.first setTitle:@"250" forState:UIControlStateNormal];
  [self.first setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
  [self.first setTitleColor:[UIColor blackColor] forState:UIControlStateSelected];
  [self.first addTarget:self action:@selector(firstFrequencyPressed) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.first];

  self.firstLabel.backgroundColor = [UIColor whiteColor];
  self.firstLabel.text = @"0";
  self.firstLabel.textColor = [UIColor redColor];
  [self.view addSubview:self.firstLabel];

  self.second.backgroundColor = [UIColor whiteColor];
  [self.second setTitle:@"500" forState:UIControlStateNormal];
  [self.second setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
  [self.second setTitleColor:[UIColor blackColor] forState:UIControlStateSelected];

  [self.second addTarget:self action:@selector(secondFrequencyPressed) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.second];

  self.secondLabel.backgroundColor = [UIColor whiteColor];
  self.secondLabel.text = @"0";
  self.secondLabel.textColor = [UIColor redColor];
  [self.view addSubview:self.secondLabel];

  self.third.backgroundColor = [UIColor whiteColor];
  [self.third setTitle:@"1000" forState:UIControlStateNormal];
  [self.third setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
  [self.third addTarget:self action:@selector(thirdFrequencyPressed) forControlEvents:UIControlEventTouchUpInside];
  [self.third setTitleColor:[UIColor blackColor] forState:UIControlStateSelected];
  [self.view addSubview:self.third];

  self.thirdLabel.backgroundColor = [UIColor whiteColor];
  self.thirdLabel.text = @"0";
  self.thirdLabel.textColor = [UIColor redColor];
  [self.view addSubview:self.thirdLabel];

  self.fourth.backgroundColor = [UIColor whiteColor];
  [self.fourth setTitle:@"20000" forState:UIControlStateNormal];
  [self.fourth setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
  [self.fourth addTarget:self action:@selector(fourthFrequencyPressed) forControlEvents:UIControlEventTouchUpInside];
  [self.fourth setTitleColor:[UIColor blackColor] forState:UIControlStateSelected];
  [self.view addSubview:self.fourth];

  self.fourthLabel.backgroundColor = [UIColor whiteColor];
  self.fourthLabel.text = @"0";
  self.fourthLabel.textColor = [UIColor redColor];
  [self.view addSubview:self.fourthLabel];

  self.play.backgroundColor = [UIColor whiteColor];
  [self.play setTitle:@"Play" forState:UIControlStateNormal];
  [self.play setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
  [self.play addTarget:self action:@selector(playPressed) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.play];

  self.pause.backgroundColor = [UIColor whiteColor];
  [self.pause setTitle:@"Pause" forState:UIControlStateNormal];
  [self.pause setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
  [self.pause addTarget:self action:@selector(pausePressed) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.pause];

  self.increaseGain.backgroundColor = [UIColor whiteColor];
  [self.increaseGain setTitle:@"Increase Gain" forState:UIControlStateNormal];
  [self.increaseGain setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
  [self.increaseGain addTarget:self action:@selector(increaseGainPressed) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.increaseGain];

  self.decreaseGain.backgroundColor = [UIColor whiteColor];
  [self.decreaseGain setTitle:@"Decrease Gain" forState:UIControlStateNormal];
  [self.decreaseGain setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
  [self.decreaseGain addTarget:self action:@selector(decreaseGainPressed) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.decreaseGain];
}

- (void)firstFrequencyPressed {
  self.first.selected = !self.first.selected;
}

- (void)secondFrequencyPressed {
  self.second.selected = !self.second.selected;
}

- (void)thirdFrequencyPressed {
  self.third.selected = !self.third.selected;
}

- (void)fourthFrequencyPressed {
  self.fourth.selected = !self.fourth.selected;
}

- (void)playPressed {
  [self.player play];
}

- (void)pausePressed {
  [self.player pause];
}

- (void)setFirstGain:(NSInteger)firstGain {
  _firstGain = [self clampGain:firstGain];
}

- (void)setSecondGain:(NSInteger)secondGain {
  _secondGain = [self clampGain:secondGain];
}

- (void)setThirdGain:(NSInteger)thirdGain {
  _thirdGain = [self clampGain:thirdGain];
}

- (void)setFourthGain:(NSInteger)fourthGain {
  _fourthGain = [self clampGain:fourthGain];
}

- (NSInteger)clampGain:(NSInteger)gain {
  NSInteger dogs = gain  > 78 ? 78 : gain;
  return dogs < -96 ? -96 : dogs;
}

- (void)updateGainLabels {
  NSString *string = [NSString stringWithFormat:@"%ld", (long)self.firstGain];
  self.firstLabel.text = string;
  string = [NSString stringWithFormat:@"%ld", (long)self.secondGain];
  self.secondLabel.text = string;
  string = [NSString stringWithFormat:@"%ld", (long)self.thirdGain];
  self.thirdLabel.text = string;
  string = [NSString stringWithFormat:@"%ld", (long)self.fourthGain];
  self.fourthLabel.text = string;
}

- (void)updateGain {
  [self updateGainLabels];
  AudioUnitSetParameter(self.privateAudioUnit, kAUNBandEQParam_Gain + (UInt32)1, kAudioUnitScope_Global, 0, (AudioUnitParameterValue)self.firstGain, 0);
  AudioUnitSetParameter(self.privateAudioUnit, kAUNBandEQParam_Gain + (UInt32)2, kAudioUnitScope_Global, 0, (AudioUnitParameterValue)self.secondGain, 0);
  AudioUnitSetParameter(self.privateAudioUnit, kAUNBandEQParam_Gain + (UInt32)3, kAudioUnitScope_Global, 0, (AudioUnitParameterValue)self.thirdGain, 0);
  AudioUnitSetParameter(self.privateAudioUnit, kAUNBandEQParam_Gain + (UInt32)5, kAudioUnitScope_Global, 0, (AudioUnitParameterValue)self.fourthGain, 0);
}

- (void)decreaseGainPressed {
  if (self.first.selected) {
    self.firstGain -=4;
  }

  if (self.second.selected) {
    self.secondGain -= 4;
  }

  if (self.third.selected) {
    self.thirdGain -= 4;
  }

  if (self.fourth.selected) {
    self.fourthGain -= 4;
  }

  [self updateGain];
}

- (void)increaseGainPressed {
  if (self.first.selected) {
    self.firstGain +=4;
  }

  if (self.second.selected) {
    self.secondGain += 4;
  }

  if (self.third.selected) {
    self.thirdGain += 4;
  }

  if (self.fourth.selected) {
    self.fourthGain += 4;
  }
  [self updateGain];
}



static float *DemonstratevDSP_fft_zrip(FFTSetup Setup, float *signal, size_t size) {
  /*  Define a stride for the array be passed to the FFT.  In many
   applications, the stride is one and is passed to the vDSP
   routine as a constant.
   */
  const vDSP_Stride Stride = 1;

  // Allocate memory for the arrays.
  float *ObservedMemory = (float *)malloc(8192 * sizeof *ObservedMemory);


  // Assign half of ObservedMemory to reals and half to imaginaries.
  DSPSplitComplex Observed = { ObservedMemory, ObservedMemory + size/2 };


  vDSP_ctoz((DSPComplex *) signal, 2*Stride, &Observed, 1, size/2);

  // Perform a real-to-complex FFT.
  vDSP_fft_zrip(Setup, &Observed, 1, std::ceil(std::log2(size)), FFT_FORWARD);


  vDSP_ctoz((DSPComplex *)signal, 2*Stride, &Observed, 1, size/2);
  vDSP_fft_zrip(Setup, &Observed, 1, std::ceil(std::log2(size)), FFT_FORWARD);

  float *dogs = (float *)malloc(size / 2 * sizeof(float));
  vDSP_zvabs(&Observed, 1, dogs, 1, size / 2);


  // Release resources.
  free(ObservedMemory);
  return dogs;
}

@end
