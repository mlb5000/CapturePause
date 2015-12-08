//
//  CameraEngine.h
//  Encoder Demo
//
//  Created by Geraint Davies on 19/02/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

#import <Foundation/Foundation.h>
#import "AVFoundation/AVCaptureSession.h"
#import "AVFoundation/AVCaptureOutput.h"
#import "AVFoundation/AVCaptureDevice.h"
#import "AVFoundation/AVCaptureInput.h"
#import "AVFoundation/AVCaptureVideoPreviewLayer.h"
#import "AVFoundation/AVMediaFormat.h"

@interface CameraEngine : NSObject

+ (CameraEngine*) engine;
- (void) startup:(NSString*)filePath;
- (void) shutdown;
- (AVCaptureVideoPreviewLayer*) getPreviewLayer;

- (void) startCapture:(AVCaptureVideoOrientation)orientation;
- (void) pauseCapture;
- (void) stopCapture:(void (^)(void))handler;
- (void) resumeCapture;
- (void) switchCamera:(AVCaptureVideoOrientation)orientation;
- (BOOL) cameraHasFlash;
- (void) takePicture:(void (^)(CMSampleBufferRef imageDataSampleBuffer, NSError *error))handler;
- (void) selectFlash:(AVCaptureFlashMode)flashMode torch:(AVCaptureTorchMode)torchMode;
- (BOOL) isFlashModeSupported:(AVCaptureFlashMode)flashMode;
- (BOOL) isTorchModeSupported:(AVCaptureTorchMode)torchMode;

@property (atomic, readwrite) BOOL isCapturing;
@property (atomic, readwrite) BOOL isPaused;
@property (atomic, readwrite) BOOL hasFinished;

@end
