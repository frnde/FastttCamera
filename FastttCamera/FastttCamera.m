//
//  FastttCamera.m
//  FastttCamera
//
//  Created by Laura Skelton on 2/5/15.
//
//

#import "FastttCamera.h"
#import "IFTTTDeviceOrientation.h"
#import "UIImage+FastttCamera.h"
#import "AVCaptureDevice+FastttCamera.h"
#import "FastttFocus.h"
#import "FastttZoom.h"
#import "FastttCapturedImage+Process.h"

@interface FastttCamera () <FastttFocusDelegate, FastttZoomDelegate>

@property (nonatomic, strong) IFTTTDeviceOrientation *deviceOrientation;
@property (nonatomic, strong) FastttFocus *fastFocus;
@property (nonatomic, strong) FastttZoom *fastZoom;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) AVCaptureStillImageOutput *stillImageOutput;
@property (nonatomic, assign) BOOL deviceAuthorized;
@property (nonatomic, assign) BOOL isCapturingImage;

//Background
@property (nonatomic, strong) NSOperationQueue *queue;
- (void)enqueue:(void(^)())block;
- (void)toMainThread:(void(^)())block;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTaskId;
- (void)startBackgroundTask;
- (void)endBackgroundTask;

//KVO
@property (nonatomic, assign) BOOL running;

@end

@implementation FastttCamera

@synthesize delegate = _delegate,
            returnsRotatedPreview = _returnsRotatedPreview,
            showsFocusView = _showsFocusView,
            maxScaledDimension = _maxScaledDimension,
            normalizesImageOrientations = _normalizesImageOrientations,
            cropsImageToVisibleAspectRatio = _cropsImageToVisibleAspectRatio,
            interfaceRotatesWithOrientation = _interfaceRotatesWithOrientation,
            fixedInterfaceOrientation = _fixedInterfaceOrientation,
            handlesTapFocus = _handlesTapFocus,
            handlesZoom = _handlesZoom,
            maxZoomFactor = _maxZoomFactor,
            showsZoomView = _showsZoomView,
            gestureView = _gestureView,
            gestureDelegate = _gestureDelegate,
            scalesImage = _scalesImage,
            cameraDevice = _cameraDevice,
            cameraFlashMode = _cameraFlashMode,
            cameraTorchMode = _cameraTorchMode,
            startCameraAutomatically = _startCameraAutomatically;

- (instancetype)init
{
    if ((self = [super init])) {
        _bgTaskId = UIBackgroundTaskInvalid;
        _running = NO;
        _startCameraAutomatically = YES;

        [self _setupCaptureSession];
        
        _handlesTapFocus = YES;
        _showsFocusView = YES;
        _handlesZoom = YES;
        _showsZoomView = YES;
        _cropsImageToVisibleAspectRatio = YES;
        _scalesImage = YES;
        _maxScaledDimension = 0.f;
        _maxZoomFactor = 1.f;
        _normalizesImageOrientations = YES;
        _returnsRotatedPreview = YES;
        _interfaceRotatesWithOrientation = YES;
        _fixedInterfaceOrientation = UIDeviceOrientationPortrait;
        _cameraDevice = FastttCameraDeviceRear;
        _cameraFlashMode = FastttCameraFlashModeOff;
        _cameraTorchMode = FastttCameraTorchModeOff;

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillEnterForeground:)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillResignActive:)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
    }
    
    return self;
}

- (void)dealloc
{
    _fastFocus = nil;
    _fastZoom = nil;
    
    [self _teardownCaptureSession];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Background

- (NSOperationQueue *)queue
{
    if (!_queue) {
        _queue = [NSOperationQueue new];
        _queue.name = @"FastttQueue";
        _queue.maxConcurrentOperationCount = 1;
    }
    return _queue;
}

- (void)enqueue:(void (^)())block
{
    [self.queue addOperationWithBlock:block];
}

- (void)toMainThread:(void (^)())block
{
    [[NSOperationQueue mainQueue] addOperationWithBlock:block];
}

- (void)startBackgroundTask
{
    if (self.bgTaskId != UIBackgroundTaskInvalid) {
        return;
    }
    
    self.bgTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [self setBgTaskId:UIBackgroundTaskInvalid];
        [self startBackgroundTask];
    }];
}

- (void)endBackgroundTask
{
    if (self.bgTaskId == UIBackgroundTaskInvalid) {
        return;
    }
    
    [[UIApplication sharedApplication] endBackgroundTask:self.bgTaskId];
    self.bgTaskId = UIBackgroundTaskInvalid;
}

#pragma mark - View Events

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self _insertPreviewLayer];
    
    UIView *viewForGestures = self.view;
    
    if (self.gestureView) {
        viewForGestures = self.gestureView;
    }
    
    _fastFocus = [FastttFocus fastttFocusWithView:viewForGestures gestureDelegate:self.gestureDelegate];
    self.fastFocus.delegate = self;
    
    if (!self.handlesTapFocus) {
        self.fastFocus.detectsTaps = NO;
    }
    
    _fastZoom = [FastttZoom fastttZoomWithView:viewForGestures gestureDelegate:self.gestureDelegate];
    self.fastZoom.delegate = self;
    
    if (!self.handlesZoom) {
        self.fastZoom.detectsPinch = NO;
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    if (_startCameraAutomatically) {
        [self startRunning];
    }
    
    [self _insertPreviewLayer];
    
    [self _setPreviewVideoOrientation];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    if (self.handlesTapFocus &&
        _session.isRunning)
    {
        [self handleTapFocusAtPoint:self.view.center];
    }
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    
    [self stopRunning];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    _previewLayer.frame = self.view.layer.bounds;
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    [self _setupCaptureSession];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    if (self.isViewLoaded && self.view.window) {
        [self startRunning];
        [self _insertPreviewLayer];
        [self _setPreviewVideoOrientation];
        if ([self.delegate respondsToSelector:@selector(cameraControllerDidResume:)]) {
            [self.delegate cameraControllerDidResume:self];
        }
        if (self.handlesTapFocus &&
            _session.isRunning)
        {
            [self handleTapFocusAtPoint:self.view.center];
        }
    }
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    if ([self.delegate respondsToSelector:@selector(cameraControllerDidPause:)]) {
        [self.delegate cameraControllerDidPause:self];
    }
    [self stopRunning];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    [self _teardownCaptureSession];
}

#pragma mark - Autorotation

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAll;
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [self _setPreviewVideoOrientation];
}

#pragma mark - Taking a Photo

- (BOOL)isReadyToCapturePhoto
{
    return !self.isCapturingImage;
}

- (void)takePicture
{
    if (!_deviceAuthorized) {
        return;
    }
    
    if (self.handlesTapFocus && self.fastFocus.isFocusing) { //We'll wait for the focus operation to finish
        self.isCapturingImage = YES;
    }
    
    [self _takePhoto];
}

- (void)cancelImageProcessing
{
    if (_isCapturingImage) {
        _isCapturingImage = NO;
    }
}

#pragma mark - Processing a Photo

- (void)processImage:(UIImage *)image withMaxDimension:(CGFloat)maxDimension
{
    __weak typeof(self)weakSelf = self;
    [self enqueue:^{
        [weakSelf _processImage:image withCropRect:CGRectNull maxDimension:maxDimension fromCamera:NO needsPreviewRotation:NO previewOrientation:UIDeviceOrientationUnknown];
    }];
}

- (void)processImage:(UIImage *)image withCropRect:(CGRect)cropRect
{
    __weak typeof(self)weakSelf = self;
    [self enqueue:^{
        [weakSelf _processImage:image withCropRect:cropRect maxDimension:0.f fromCamera:NO needsPreviewRotation:NO previewOrientation:UIDeviceOrientationUnknown];
    }];
}

- (void)processImage:(UIImage *)image withCropRect:(CGRect)cropRect maxDimension:(CGFloat)maxDimension
{
    __weak typeof(self)weakSelf = self;
    [self enqueue:^{
        [weakSelf _processImage:image withCropRect:cropRect maxDimension:maxDimension fromCamera:NO needsPreviewRotation:NO previewOrientation:UIDeviceOrientationUnknown];
    }];
}

#pragma mark - Camera State

+ (BOOL)isPointFocusAvailableForCameraDevice:(FastttCameraDevice)cameraDevice
{
    return [AVCaptureDevice isPointFocusAvailableForCameraDevice:cameraDevice];
}

- (BOOL)focusAtPoint:(CGPoint)touchPoint
{
    CGPoint pointOfInterest = [self _focusPointOfInterestForTouchPoint:touchPoint];
    
    return [self _focusAtPointOfInterest:pointOfInterest];
}

- (BOOL)zoomToScale:(CGFloat)scale
{
    return [[self _currentCameraDevice] zoomToScale:scale];
}

- (BOOL)isFlashAvailableForCurrentDevice
{
    AVCaptureDevice *device = [self _currentCameraDevice];
    
    if ([device isFlashModeSupported:AVCaptureFlashModeOn]) {
        return YES;
    }
    
    return NO;
}

+ (BOOL)isFlashAvailableForCameraDevice:(FastttCameraDevice)cameraDevice
{
    return [AVCaptureDevice isFlashAvailableForCameraDevice:cameraDevice];
}

- (BOOL)isTorchAvailableForCurrentDevice
{
    AVCaptureDevice *device = [self _currentCameraDevice];
    
    if ([device isTorchModeSupported:AVCaptureTorchModeOn]) {
        return YES;
    }
    
    return NO;
}

+ (BOOL)isTorchAvailableForCameraDevice:(FastttCameraDevice)cameraDevice
{
    return [AVCaptureDevice isTorchAvailableForCameraDevice:cameraDevice];
}

+ (BOOL)isCameraDeviceAvailable:(FastttCameraDevice)cameraDevice
{
    return ([AVCaptureDevice cameraDevice:cameraDevice] != nil);
}

- (void)setCameraDevice:(FastttCameraDevice)cameraDevice
{
    AVCaptureDevice *device = [AVCaptureDevice cameraDevice:cameraDevice];
    
    if (!device) {
        return;
    }
    
    if (_cameraDevice != cameraDevice) {
        _cameraDevice = cameraDevice;
        
        AVCaptureDeviceInput *oldInput = [_session.inputs lastObject];
        AVCaptureDeviceInput *newInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:nil];
        
        [_session beginConfiguration];
        [_session removeInput:oldInput];
        [_session addInput:newInput];
        [_session commitConfiguration];
    }
    
    [self setCameraFlashMode:_cameraFlashMode];
    [self _resetZoom];
    [self.fastFocus setCurrentDevice:device];
    [self handleTapFocusAtPoint:self.view.center];
}

- (void)setCameraFlashMode:(FastttCameraFlashMode)cameraFlashMode
{
    AVCaptureDevice *device = [self _currentCameraDevice];
    
    if ([AVCaptureDevice isFlashAvailableForCameraDevice:self.cameraDevice]) {
        _cameraFlashMode = cameraFlashMode;
        [device setCameraFlashMode:cameraFlashMode];
        return;
    }
    
    _cameraFlashMode = FastttCameraFlashModeOff;
}

- (void)setCameraTorchMode:(FastttCameraTorchMode)cameraTorchMode
{
    AVCaptureDevice *device = [self _currentCameraDevice];
    
    if ([AVCaptureDevice isTorchAvailableForCameraDevice:self.cameraDevice]) {
        _cameraTorchMode = cameraTorchMode;
        [device setCameraTorchMode:cameraTorchMode];
        return;
    }
    
    _cameraTorchMode = FastttCameraTorchModeOff;
}

#pragma mark - Capture Session Management

- (void)startRunning
{
    if (![_session isRunning]) {
        [_session startRunning];
        self.running = _session.isRunning;
    }
}

- (void)stopRunning
{
    if ([_session isRunning]) {
        [_session stopRunning];
        self.running = _session.isRunning;
    }
}

- (void)_insertPreviewLayer
{
    if (!_deviceAuthorized) {
        return;
    }
    
    if ([_previewLayer superlayer] == [self.view layer]
        && [_previewLayer session] == _session) {
        return;
    }
    
    [self _removePreviewLayer];
    
    CALayer *rootLayer = [self.view layer];
    rootLayer.masksToBounds = YES;
    
    _previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:_session];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    
    _previewLayer.frame = rootLayer.bounds;
    
    [rootLayer insertSublayer:_previewLayer atIndex:0];
}

- (void)_removePreviewLayer
{
    [_previewLayer removeFromSuperlayer];
    _previewLayer = nil;
}

- (void)_setupCaptureSession
{
    if (_session) {
        return;
    }
    
    [self startBackgroundTask];
    
    __weak typeof(self)weakSelf = self;
    [self _checkDeviceAuthorizationWithCompletion:^(BOOL isAuthorized) {
        
        _deviceAuthorized = isAuthorized;
        
        [weakSelf enqueue:^{
            [weakSelf _postAuthorizationSetup];
        }];
    }];
}

- (void)_teardownCaptureSession
{
    if (!_session) {
        return;
    }
    
    _deviceOrientation = nil;
    
    if ([_session isRunning]) {
        [_session stopRunning];
    }
    
    for (AVCaptureDeviceInput *input in [_session inputs]) {
        [_session removeInput:input];
    }
    
    [_session removeOutput:_stillImageOutput];
    _stillImageOutput = nil;
    
    [self _removePreviewLayer];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVCaptureSessionRuntimeErrorNotification
                                                  object:_session];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVCaptureSessionWasInterruptedNotification
                                                  object:_session];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVCaptureSessionInterruptionEndedNotification
                                                  object:_session];
    
    _session = nil;
    
    [self endBackgroundTask];
}

#pragma mark - Capturing a Photo

- (void)_takePhoto
{
    if (self.isCapturingImage) {
        return;
    }
    self.isCapturingImage = YES;
    
    BOOL needsPreviewRotation = ![self.deviceOrientation deviceOrientationMatchesInterfaceOrientation];
    
    AVCaptureConnection *videoConnection = [self _currentCaptureConnection];
    
    if ([videoConnection isVideoOrientationSupported]) {
        [videoConnection setVideoOrientation:[self _currentCaptureVideoOrientationForDevice]];
    }
    
    if ([videoConnection isVideoMirroringSupported]) {
        [videoConnection setVideoMirrored:(_cameraDevice == FastttCameraDeviceFront)];
    }
    
    /*
        AVCaptureFocusModeContinuousAutoFocus, AVCaptureExposureModeContinuousAutoExposure and 
        AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance are a bit too anxious at times and
        may start refocusing after starting to take a photo but before arriving at
        `captureStillImageAsynchronouslyFromConnection:completionHandler:`.
        This may lead to multiple pictures being snapped when we're listening to
        `hasFinishedAdjustingFocusAndExposure` events.
        To avoid this scenario, we try to lock the camera device before snapping a picture.
     */
    AVCaptureDevice *device = [[_session.inputs lastObject] device];
    if ([device lockForConfiguration:nil]) {
        if ([device isFocusModeSupported:AVCaptureFocusModeLocked]) {
            device.focusMode = AVCaptureFocusModeLocked;
        }
        
        if ([device isExposureModeSupported:AVCaptureExposureModeLocked]) {
            device.exposureMode = AVCaptureExposureModeLocked;
        }
        
        if ([device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeLocked]) {
            device.whiteBalanceMode = AVCaptureWhiteBalanceModeLocked;
        }
        [device unlockForConfiguration];
    }
    
    __weak typeof(self)weakSelf = self;
    
#if TARGET_IPHONE_SIMULATOR
    [self _insertPreviewLayer];
    [self enqueue:^{
        UIImage *fakeImage = [UIImage fastttFakeTestImage];
        [weakSelf _processCameraPhoto:fakeImage needsPreviewRotation:needsPreviewRotation previewOrientation:UIDeviceOrientationPortrait];
    }];
#else    
    UIDeviceOrientation previewOrientation = [self _currentPreviewDeviceOrientation];

    [_stillImageOutput captureStillImageAsynchronouslyFromConnection:videoConnection
                                                   completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error)
     {
         if (!imageDataSampleBuffer) {
             return;
         }
         
         if (![weakSelf isCapturingImage]) {
             return;
         }
         
         NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];

         if ([[weakSelf delegate] respondsToSelector:@selector(cameraController:didFinishCapturingImageData:)]) {
             [weakSelf toMainThread:^{
                 [[weakSelf delegate] cameraController:weakSelf didFinishCapturingImageData:imageData];
             }];
         }

         [weakSelf enqueue:^{
             UIImage *image = [UIImage imageWithData:imageData];
             
             [weakSelf _processCameraPhoto:image needsPreviewRotation:needsPreviewRotation previewOrientation:previewOrientation];
         }];
     }];
#endif
}

#pragma mark - Processing a Photo

- (void)_processCameraPhoto:(UIImage *)image needsPreviewRotation:(BOOL)needsPreviewRotation previewOrientation:(UIDeviceOrientation)previewOrientation
{
    CGRect cropRect = CGRectNull;
    if (self.cropsImageToVisibleAspectRatio) {
        cropRect = [image fastttCropRectFromPreviewLayer:_previewLayer];
    }
    
    [self _processImage:image withCropRect:cropRect maxDimension:self.maxScaledDimension fromCamera:YES needsPreviewRotation:(needsPreviewRotation || !self.interfaceRotatesWithOrientation) previewOrientation:previewOrientation];
}

- (void)_processImage:(UIImage *)image withCropRect:(CGRect)cropRect maxDimension:(CGFloat)maxDimension fromCamera:(BOOL)fromCamera needsPreviewRotation:(BOOL)needsPreviewRotation previewOrientation:(UIDeviceOrientation)previewOrientation
{
    if (fromCamera && !self.isCapturingImage) {
        return;
    }
    
    __weak typeof(self)weakSelf = self;
    
    FastttCapturedImage *capturedImage = [FastttCapturedImage fastttCapturedFullImage:image];
    
    [capturedImage cropToRect:cropRect
               returnsPreview:(fromCamera && self.returnsRotatedPreview)
         needsPreviewRotation:needsPreviewRotation
       withPreviewOrientation:previewOrientation
                 withCallback:^(FastttCapturedImage *capturedImage){
                     if (fromCamera && !self.isCapturingImage) {
                         return;
                     }
                     if ([self.delegate respondsToSelector:@selector(cameraController:didFinishCapturingImage:)]) {
                         [self toMainThread:^{
                             [[weakSelf delegate] cameraController:weakSelf didFinishCapturingImage:capturedImage];
                         }];
                     }
                 }];
    
    void (^scaleCallback)(FastttCapturedImage *capturedImage) = ^(FastttCapturedImage *capturedImage) {
        if (fromCamera && !self.isCapturingImage) {
            return;
        }
        if ([self.delegate respondsToSelector:@selector(cameraController:didFinishScalingCapturedImage:)]) {
            [self toMainThread:^{
                [[weakSelf delegate] cameraController:weakSelf didFinishScalingCapturedImage:capturedImage];
            }];
        }
    };
    
    if (fromCamera && !self.isCapturingImage) {
        return;
    }
    
    if (maxDimension > 0.f) {
        [capturedImage scaleToMaxDimension:maxDimension
                              withCallback:scaleCallback];
    } else if (fromCamera && self.scalesImage) {
        [capturedImage scaleToSize:self.view.bounds.size
                      withCallback:scaleCallback];
    }
    
    if (fromCamera && !self.isCapturingImage) {
        return;
    }
    
    if (self.normalizesImageOrientations) {
        [capturedImage normalizeWithCallback:^(FastttCapturedImage *capturedImage){
            if (fromCamera && !self.isCapturingImage) {
                return;
            }
            if ([self.delegate respondsToSelector:@selector(cameraController:didFinishNormalizingCapturedImage:)]) {
                [self toMainThread:^{
                    [[weakSelf delegate] cameraController:weakSelf didFinishNormalizingCapturedImage:capturedImage];
                }];
            }
        }];
    }
    
    self.isCapturingImage = NO;
}

#pragma mark - AV Orientation

- (void)_setPreviewVideoOrientation
{
    AVCaptureConnection *videoConnection = [_previewLayer connection];
    
    if ([videoConnection isVideoOrientationSupported]) {
        [videoConnection setVideoOrientation:[self _currentPreviewVideoOrientationForDevice]];
    }
}

- (AVCaptureVideoOrientation)_currentCaptureVideoOrientationForDevice
{
    UIDeviceOrientation actualOrientation = self.deviceOrientation.orientation;
    
    if (actualOrientation == UIDeviceOrientationFaceDown
        || actualOrientation == UIDeviceOrientationFaceUp
        || actualOrientation == UIDeviceOrientationUnknown) {
        return [self _currentPreviewVideoOrientationForDevice];
    }
    
    return [self.class _videoOrientationForDeviceOrientation:actualOrientation];
}

- (UIDeviceOrientation)_currentPreviewDeviceOrientation
{
    if (!self.interfaceRotatesWithOrientation) {
        return self.fixedInterfaceOrientation;
    }
    
    return [[UIDevice currentDevice] orientation];
}

- (AVCaptureVideoOrientation)_currentPreviewVideoOrientationForDevice
{
    UIDeviceOrientation deviceOrientation = [self _currentPreviewDeviceOrientation];

    return [self.class _videoOrientationForDeviceOrientation:deviceOrientation];
}

+ (AVCaptureVideoOrientation)_videoOrientationForDeviceOrientation:(UIDeviceOrientation)deviceOrientation
{
    switch (deviceOrientation) {
        case UIDeviceOrientationPortrait:
            return AVCaptureVideoOrientationPortrait;
            
        case UIDeviceOrientationPortraitUpsideDown:
            return AVCaptureVideoOrientationPortraitUpsideDown;
            
        case UIDeviceOrientationLandscapeLeft:
            return AVCaptureVideoOrientationLandscapeRight;
            
        case UIDeviceOrientationLandscapeRight:
            return AVCaptureVideoOrientationLandscapeLeft;
            
        default:
            break;
    }
    
    return AVCaptureVideoOrientationPortrait;
}

#pragma mark - Camera Permissions

- (void)_checkDeviceAuthorizationWithCompletion:(void (^)(BOOL isAuthorized))completion
{
#if TARGET_IPHONE_SIMULATOR
    if (completion) {
        completion(YES);
    }
#else
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        if (completion) {
            completion(granted);
        }
    }];
#endif
}

- (void)_postAuthorizationSetup
{
    __weak typeof(self)weakSelf = self;
    
    if (!_deviceAuthorized && [[weakSelf delegate] respondsToSelector:@selector(userDeniedCameraPermissionsForCameraController:)]) {
        [self toMainThread:^{
            [[weakSelf delegate] userDeniedCameraPermissionsForCameraController:weakSelf];
        }];
    }
    
    if (_deviceAuthorized) {
        
        _session = [AVCaptureSession new];
        _session.sessionPreset = AVCaptureSessionPresetPhoto;
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_sessionRuntimeError:)
                                                     name:AVCaptureSessionRuntimeErrorNotification
                                                   object:_session];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_sessionWasInterrupted:)
                                                     name:AVCaptureSessionWasInterruptedNotification
                                                   object:_session];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_sessionInterruptionEnded:)
                                                     name:AVCaptureSessionInterruptionEndedNotification
                                                   object:_session];
        
        AVCaptureDevice *device = [AVCaptureDevice cameraDevice:self.cameraDevice];
        
        if (!device) {
            device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        }
        
        if (!self.handlesTapFocus) {
            if ([device lockForConfiguration:nil]) {
                if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
                    device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
                } else if ([device isFocusModeSupported:AVCaptureFocusModeLocked]) {
                    device.focusMode = AVCaptureFocusModeLocked;
                }
                
                if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
                    device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
                } else if ([device isExposureModeSupported:AVCaptureExposureModeLocked]) {
                    device.exposureMode = AVCaptureExposureModeLocked;
                }
                
                if ([device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) {
                    device.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
                } else if ([device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeLocked]) {
                    device.whiteBalanceMode = AVCaptureWhiteBalanceModeLocked;
                }
                [device unlockForConfiguration];
            }
            
        } //Else, we're handling this on viewDidAppear or on applicationDidBecomeActive
        
#if !TARGET_IPHONE_SIMULATOR
        AVCaptureDeviceInput *deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:nil];
        [_session addInput:deviceInput];
        
        switch (device.position) {
            case AVCaptureDevicePositionBack:
                _cameraDevice = FastttCameraDeviceRear;
                break;
                
            case AVCaptureDevicePositionFront:
                _cameraDevice = FastttCameraDeviceFront;
                break;
                
            default:
                break;
        }
        
        [self setCameraFlashMode:_cameraFlashMode];
#endif
        
        NSDictionary *outputSettings = @{AVVideoCodecKey:AVVideoCodecJPEG};
        
        _stillImageOutput = [AVCaptureStillImageOutput new];
        _stillImageOutput.outputSettings = outputSettings;
        
        [_session addOutput:_stillImageOutput];
        
        _deviceOrientation = [IFTTTDeviceOrientation new];
        
        if (self.isViewLoaded && self.view.window) {
            if (_startCameraAutomatically) {
                [self startRunning];
            }
            [self toMainThread:^{
                [weakSelf _insertPreviewLayer];
                [weakSelf _setPreviewVideoOrientation];
                [weakSelf _resetZoom];
            }];
        }
    }
}

#pragma mark - FastttCameraDevice

- (AVCaptureDevice *)_currentCameraDevice
{
    return [_session.inputs.lastObject device];
}

- (AVCaptureConnection *)_currentCaptureConnection
{
    AVCaptureConnection *videoConnection = nil;
    
    for (AVCaptureConnection *connection in [_stillImageOutput connections]) {
        for (AVCaptureInputPort *port in [connection inputPorts]) {
            if ([[port mediaType] isEqual:AVMediaTypeVideo]) {
                videoConnection = connection;
                break;
            }
        }
        
        if (videoConnection) {
            break;
        }
    }
    
    return videoConnection;
}

- (CGPoint)_focusPointOfInterestForTouchPoint:(CGPoint)touchPoint
{
    return [_previewLayer captureDevicePointOfInterestForPoint:touchPoint];
}

- (BOOL)_focusAtPointOfInterest:(CGPoint)pointOfInterest
{
    return [[self _currentCameraDevice] focusAtPointOfInterest:pointOfInterest];
}

- (void)_resetZoom
{
    [self.fastZoom resetZoom];
    
    self.fastZoom.maxScale = [[self _currentCameraDevice] videoMaxZoomFactor];
    
    self.maxZoomFactor = self.fastZoom.maxScale;
}

#pragma mark - FastttFocusDelegate

- (BOOL)handleTapFocusAtPoint:(CGPoint)touchPoint
{
    if ([AVCaptureDevice isPointFocusAvailableForCameraDevice:self.cameraDevice]) {
        
        CGPoint pointOfInterest = [self _focusPointOfInterestForTouchPoint:touchPoint];
        
        return ([self _focusAtPointOfInterest:pointOfInterest] && self.showsFocusView);
    }
    
    return NO;
}

- (void)hasFinishedAdjustingFocusAndExposure
{
    if (self.handlesTapFocus && self.isCapturingImage) { //We were waiting for the focus to finish, but now we can snap the picture
        self.isCapturingImage = NO;
        [self _takePhoto];
    }
}

#pragma mark - FastttZoomDelegate

- (BOOL)handlePinchZoomWithScale:(CGFloat)zoomScale
{
    return ([self zoomToScale:zoomScale] && self.showsZoomView);
}

#pragma mark - Error handling

/*  
    These three methods were based on Apple's AVCam.
    @see https://developer.apple.com/library/ios/samplecode/AVCam/Introduction/Intro.html
 */

- (void)_sessionRuntimeError:(NSNotification *)notification
{
    NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
    if (error.code == AVErrorMediaServicesWereReset) {
        if (self.isRunning) {
            __weak typeof(self)weakSelf = self;
            [self enqueue:^{
                [weakSelf startRunning];
            }];
        }
        return;
    }
    [self _teardownCaptureSession];
    if ([self.delegate respondsToSelector:@selector(cameraControllerDidPause:)]) {
        __weak typeof(self)weakSelf = self;
        [self toMainThread:^{
            [[weakSelf delegate] cameraControllerDidPause:weakSelf];
        }];
    }
}

- (void)_sessionWasInterrupted:(NSNotification *)notification
{
    if (&AVCaptureSessionInterruptionReasonKey) {
        AVCaptureSessionInterruptionReason reason = [notification.userInfo[AVCaptureSessionInterruptionReasonKey] integerValue];
        if (reason == AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground) {
            //We're stopping the camera anyway
            return;
        }
    }
    
    if ([self.delegate respondsToSelector:@selector(cameraControllerDidPause:)]) {
        __weak typeof(self)weakSelf = self;
        [self toMainThread:^{
            [[weakSelf delegate] cameraControllerDidPause:weakSelf];
        }];
    }
}

- (void)_sessionInterruptionEnded:(NSNotification *)notification
{
    if ([self.delegate respondsToSelector:@selector(cameraControllerDidPause:)]) {
        __weak typeof(self)weakSelf = self;
        [self toMainThread:^{
            [[weakSelf delegate] cameraControllerDidResume:weakSelf];
        }];
    }
}

@end
