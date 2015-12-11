//
//  CameraEngine.m
//  Encoder Demo
//
//  Created by Geraint Davies on 19/02/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

#import "CameraEngine.h"
#import "VideoEncoder.h"
#import "AssetsLibrary/ALAssetsLibrary.h"
@import AVFoundation;

static CameraEngine* theEngine;

@interface CameraEngine  () <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
{
    AVCaptureSession* _session;
    AVCaptureVideoPreviewLayer* _preview;
    dispatch_queue_t _captureQueue;
    AVCaptureConnection* _audioConnection;
    AVCaptureConnection* _videoConnection;
    NSString *_filePath;
    AVCaptureVideoDataOutput *_videoout;
    AVCaptureAudioDataOutput* _audioout;
    AVCaptureStillImageOutput *_pictureOutput;
    
    AVCaptureDevice *_captureVideoDevice;
    AVCaptureDeviceInput *_captureVideoInput;
    AVCaptureDevice *_audioCaptureDevice;
    AVCaptureDeviceInput *_audioCaptureInput;
    
    VideoEncoder* _encoder;
    BOOL _isCapturing;
    BOOL _isPaused;
    BOOL _discont;
    BOOL _hasFinished;
    BOOL _hasSeenVideo;
    CMTime _timeOffset;
    CMTime _lastVideo;
    CMTime _lastAudio;
    AVCaptureVideoOrientation _currentOrientation;
    
    long _cx;
    long _cy;
    int _channels;
    Float64 _samplerate;
}
@end


@implementation CameraEngine

@synthesize isCapturing = _isCapturing;
@synthesize isPaused = _isPaused;

+ (void) initialize
{
    // test recommended to avoid duplicate init via subclass
    if (self == [CameraEngine class])
    {
        theEngine = [[CameraEngine alloc] init];
    }
}

+ (CameraEngine*) engine
{
    return theEngine;
}

- (void) startup:(NSString*)filePath
{
    if (_session == nil)
    {
        NSLog(@"Starting up server");
        
        if (filePath) {
            _filePath = filePath;
        }
        
        // Configure Mic to built in mic
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
        [audioSession setActive:YES error:nil];
        
        NSArray *inputs = audioSession.availableInputs;
        AVAudioSessionPortDescription *mic = nil;
        for (AVAudioSessionPortDescription *port in inputs) {
            if (port.portType == AVAudioSessionPortBuiltInMic) {
                mic = port;
                break;
            }
        }
        if (mic) {
            NSArray *sources = mic.dataSources;
            for (AVAudioSessionDataSourceDescription *source in sources) {
                if (source.orientation == AVAudioSessionOrientationFront) {
                    [mic setPreferredDataSource:source error:nil];
                    [audioSession setPreferredInput:mic error:nil];
                    break;
                }
            }
        }

        self.hasFinished = NO;
        self.isCapturing = NO;
        self.isPaused = NO;
        _discont = NO;
        _encoder = nil;
        
        // create capture device with video input
        _session = [[AVCaptureSession alloc] init];
        _captureVideoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        _captureVideoInput = [AVCaptureDeviceInput deviceInputWithDevice:_captureVideoDevice error:nil];
        if (_captureVideoInput) {
            [_session addInput:_captureVideoInput];
        }
        
        // audio input from default mic
        _audioCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        _audioCaptureInput = [AVCaptureDeviceInput deviceInputWithDevice:_audioCaptureDevice error:nil];
        
        if (_audioCaptureInput) {
            [_session addInput:_audioCaptureInput];
        }
        
        // create an output for YUV output with self as delegate
        _captureQueue = dispatch_queue_create("uk.co.gdcl.cameraengine.capture", DISPATCH_QUEUE_SERIAL);
        
        // for audio, we want the channels and sample rate, but we can't get those from audioout.audiosettings on ios, so
        // we need to wait for the first sample
        _videoout = [[AVCaptureVideoDataOutput alloc] init];
        NSDictionary* setcapSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                        [NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange], kCVPixelBufferPixelFormatTypeKey,
                                        nil];
        _videoout.videoSettings = setcapSettings;
        [_session addOutput:_videoout];
        _videoConnection = [_videoout connectionWithMediaType:AVMediaTypeVideo];
        
        _audioout = [[AVCaptureAudioDataOutput alloc] init];
        [_session addOutput:_audioout];
        _audioConnection = [_audioout connectionWithMediaType:AVMediaTypeAudio];
      
        [self preparePhotoOutput];
      
        // start capture and a preview layer
        [_session startRunning];

        _preview = [AVCaptureVideoPreviewLayer layerWithSession:_session];
        _preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    }
}

- (void) startCapture:(AVCaptureVideoOrientation)orientation
{
    @synchronized(self)
    {
        if (!self.isCapturing)
        {
            NSLog(@"starting capture");
          
            _currentOrientation = orientation;
          
            // Set the orientation before we configure the output dimensions
            _videoConnection.videoOrientation = orientation;
            
            // find the actual dimensions used so we can set up the encoder to the same.
            NSDictionary* actual = _videoout.videoSettings;
            _cy = [[actual objectForKey:@"Height"] longValue];
            _cx = [[actual objectForKey:@"Width"] longValue];
            
            [_videoout setSampleBufferDelegate:self queue:_captureQueue];
            [_audioout setSampleBufferDelegate:self queue:_captureQueue];
            
            // create the encoder once we have the audio params
            _encoder = nil;
            self.isPaused = NO;
            _discont = NO;
            _timeOffset = CMTimeMake(0, 0);
            self.isCapturing = YES;
        }
    }
}

- (void) stopCapture:(void (^)(void))handler
{
    @synchronized(self)
    {
        if (self.isCapturing)
        {
            NSURL *url = [NSURL fileURLWithPath:_filePath];
            
            // serialize with audio and video capture
            
            self.isCapturing = NO;
            
            if (self.hasFinished) {
                return;
            }
            self.hasFinished = YES;
            dispatch_async(_captureQueue, ^{
                [_encoder finishWithCompletionHandler:^{
                    self.isCapturing = NO;
                    _encoder = nil;
                    if (handler) {
                        handler();
                    }
                }];
            });
        }
    }
}

- (void) pauseCapture
{
    @synchronized(self)
    {
        if (self.isCapturing)
        {
            NSLog(@"Pausing capture");
            self.isPaused = YES;
            _discont = YES;
        }
    }
}

- (void) resumeCapture
{
    @synchronized(self)
    {
        if (self.isPaused)
        {
            NSLog(@"Resuming capture");
            self.isPaused = NO;
        }
    }
}

- (void) switchCamera:(AVCaptureVideoOrientation)orientation {
    AVCaptureDevicePosition newPosition = (_captureVideoDevice.position == AVCaptureDevicePositionFront ? AVCaptureDevicePositionBack : AVCaptureDevicePositionFront);
    
    AVCaptureDevice *newDevice = [self videoDeviceForPosition:newPosition];
    if (newDevice) {
        NSError *error = nil;
        AVCaptureDeviceInput *deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:newDevice error:&error];
      
        if (deviceInput && error == nil) {
            [_session beginConfiguration];
            [_session removeInput:_captureVideoInput];
            
            if ([_session canAddInput:deviceInput]) {
                if (_captureVideoInput != nil) {
                    [_session removeInput:_captureVideoInput];
                }
                _session.sessionPreset = AVCaptureSessionPresetHigh;
                [_session addInput:deviceInput];
                _captureVideoDevice = newDevice;
                _captureVideoInput = deviceInput;
            } else {
                [_session addInput:_captureVideoInput];
            }
            [_session commitConfiguration];
          
            _currentOrientation = orientation;
            _videoConnection = [_videoout connectionWithMediaType:AVMediaTypeVideo];
            _videoConnection.videoOrientation = _currentOrientation;
        } else {
            NSLog(@"Failed to switch camera: %@", error);
        }
    }
}

- (AVCaptureDevice *)videoDeviceForPosition:(AVCaptureDevicePosition)position {
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in devices) {
        if (device.position == position) {
            return device;
        }
    }
    
    return nil;
}

- (BOOL) cameraHasFlash {
    return [_captureVideoDevice hasFlash];
}

- (BOOL) isFlashModeSupported:(AVCaptureFlashMode)flashMode {
    return [_captureVideoDevice isFlashModeSupported:flashMode];
}

- (BOOL) isTorchModeSupported:(AVCaptureTorchMode)torchMode {
    return [_captureVideoDevice isTorchModeSupported:torchMode];
}

- (void) selectFlash:(AVCaptureFlashMode)flashMode torch:(AVCaptureTorchMode)torchMode {
    NSError *error = nil;
    BOOL *locked = [_captureVideoDevice lockForConfiguration:&error];
    if (locked && error == nil) {
        if ([self isFlashModeSupported:flashMode]) {
            _captureVideoDevice.flashMode = flashMode;
        }
        if ([self isTorchModeSupported:torchMode]) {
            _captureVideoDevice.torchMode = torchMode;
        }
        [_captureVideoDevice unlockForConfiguration];
    } else {
        NSLog(@"Error changing camera flash: %@", error);
    }
}

- (void) takePicture:(void (^)(CMSampleBufferRef imageDataSampleBuffer, NSError *error))handler {
    AVCaptureConnection *videoConnection = [_pictureOutput connectionWithMediaType:AVMediaTypeVideo];
    if (!videoConnection) {
        return;
    }
    videoConnection.videoOrientation = _videoConnection.videoOrientation;
    
    [_pictureOutput captureStillImageAsynchronouslyFromConnection:videoConnection completionHandler:handler];
}

- (void) preparePhotoOutput {
    [_session beginConfiguration];
    if (_pictureOutput) {
        [_session removeOutput:_pictureOutput];
    }
    
    _pictureOutput = [[AVCaptureStillImageOutput alloc] init];
    NSDictionary *outputSettings = [[NSDictionary alloc] initWithObjectsAndKeys: AVVideoCodecJPEG, AVVideoCodecKey, nil];
    [_pictureOutput setOutputSettings:outputSettings];
    
    if ([_session canAddOutput:_pictureOutput]) {
        [_session addOutput:_pictureOutput];
    }
    [_session commitConfiguration];
}

- (CMSampleBufferRef) adjustTime:(CMSampleBufferRef) sample by:(CMTime) offset
{
    CMItemCount count;
    CMSampleBufferGetSampleTimingInfoArray(sample, 0, nil, &count);
    CMSampleTimingInfo* pInfo = malloc(sizeof(CMSampleTimingInfo) * count);
    CMSampleBufferGetSampleTimingInfoArray(sample, count, pInfo, &count);
    for (CMItemCount i = 0; i < count; i++)
    {
        pInfo[i].decodeTimeStamp = CMTimeSubtract(pInfo[i].decodeTimeStamp, offset);
        pInfo[i].presentationTimeStamp = CMTimeSubtract(pInfo[i].presentationTimeStamp, offset);
    }
    CMSampleBufferRef sout;
    CMSampleBufferCreateCopyWithNewTiming(nil, sample, count, pInfo, &sout);
    free(pInfo);
    return sout;
}

- (BOOL) setAudioFormat:(CMFormatDescriptionRef) fmt
{
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
    if (!asbd) {
        // Protect from null pointer dereference
        return NO;
    }
    
    _samplerate = asbd->mSampleRate;
    _channels = asbd->mChannelsPerFrame;
    return YES;
}

- (void) captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    BOOL bVideo = YES;
    
    @synchronized(self)
    {
        if (!self.isCapturing  || self.isPaused)
        {
            return;
        }
        if (connection == _audioConnection)
        {
            bVideo = NO;
        }
        if (!bVideo && !_hasSeenVideo)
        {
            return;
        }
        if ((_encoder == nil) && !bVideo)
        {
            CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
            if ([self setAudioFormat:fmt] == NO) {
                return;
            }
            
            _encoder = [VideoEncoder encoderForPath:_filePath Height:(int)_cy width:(int)_cx channels:_channels samples:_samplerate];
        }
        if (_discont)
        {
            if (bVideo)
            {
                return;
            }
            _discont = NO;
            // calc adjustment
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            CMTime last = bVideo ? _lastVideo : _lastAudio;
            if (last.flags & kCMTimeFlags_Valid)
            {
                if (_timeOffset.flags & kCMTimeFlags_Valid)
                {
                    pts = CMTimeSubtract(pts, _timeOffset);
                }
                CMTime offset = CMTimeSubtract(pts, last);
                NSLog(@"Setting offset from %s", bVideo?"video": "audio");
                NSLog(@"Adding %f to %f (pts %f)", ((double)offset.value)/offset.timescale, ((double)_timeOffset.value)/_timeOffset.timescale, ((double)pts.value/pts.timescale));
                
                // this stops us having to set a scale for _timeOffset before we see the first video time
                if (_timeOffset.value == 0)
                {
                    _timeOffset = offset;
                }
                else
                {
                    _timeOffset = CMTimeAdd(_timeOffset, offset);
                }
            }
            _lastVideo.flags = 0;
            _lastAudio.flags = 0;
        }
        _hasSeenVideo = YES;
        
        // retain so that we can release either this or modified one
        CFRetain(sampleBuffer);
        
        if (_timeOffset.value > 0)
        {
            CFRelease(sampleBuffer);
            sampleBuffer = [self adjustTime:sampleBuffer by:_timeOffset];
        }
        
        // record most recent time so we know the length of the pause
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        CMTime dur = CMSampleBufferGetDuration(sampleBuffer);
        if (dur.value > 0)
        {
            pts = CMTimeAdd(pts, dur);
        }
        if (bVideo)
        {
            _lastVideo = pts;
        }
        else
        {
            _lastAudio = pts;
        }
    }

    // pass frame to encoder
    [_encoder encodeFrame:sampleBuffer isVideo:bVideo];
    CFRelease(sampleBuffer);
}

- (void) shutdown
{
    NSLog(@"shutting down server");
    if (_session)
    {
        [_session stopRunning];
        
        if (_pictureOutput) {
            [_session removeOutput:_pictureOutput];
            _pictureOutput = nil;
        }
        if (_videoout) {
            [_session removeOutput:_videoout];
            _videoout = nil;
        }
        if (_captureVideoInput) {
            [_session removeInput:_captureVideoInput];
            _captureVideoInput = nil;
        }
        if (_audioCaptureInput) {
            [_session removeInput:_audioCaptureInput];
            _audioCaptureInput = nil;
        }
        
        _session = nil;
        _captureVideoDevice = nil;
        _audioCaptureDevice = nil;
    }
    
    if (self.hasFinished) {
        return;
    }
    self.hasFinished = YES;
  
    if (_captureQueue == nil) {
        return;
    }
  
    // Must call in the same dispatch queue as encoding to ensure
    // that all writing has completed prior to calling finish.
    dispatch_async(_captureQueue, ^{
        [_encoder finishWithCompletionHandler:^{
            NSLog(@"Capture completed");
        }];
    });
}

- (AVCaptureVideoPreviewLayer*) getPreviewLayer
{
    return _preview;
}

@end
