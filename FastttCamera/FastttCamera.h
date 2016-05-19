//
//  FastttCamera.h
//  FastttCamera
//
//  Created by Laura Skelton on 2/5/15.
//
//

@import UIKit;
@import AVFoundation;

//! Project version number for viewer_protocol.
FOUNDATION_EXPORT double viewer_protocolVersionNumber;

//! Project version string for viewer_protocol.
FOUNDATION_EXPORT const unsigned char viewer_protocolVersionString[];

#import "UIViewController+FastttCamera.h"
#import "IFTTTDeviceOrientation.h"
#import "FastttCapturedImage+Process.h"
#import "FastttCameraInterface.h"
#import "FastttCameraTypes.h"
#import "AVCaptureDevice+FastttCamera.h"
#import "UIImage+FastttFilters.h"
#import "FastttZoom.h"
#import "UIImage+FastttCamera.h"
#import "FastttCapturedImage.h"
#import "FastttFocus.h"
#import "FastttFilterCamera.h"

/**
 *  Public class for you to use to create a standard FastttCamera!
 *
 *  @note The full interface for the FastttCamera can be found in
 *  the FastttCameraInterface protocol.
 *
 *  @note If you want to use filters with your live camera preview,
 *  use an instance of FastttFilterCamera instead.
 */
@interface FastttCamera : UIViewController <FastttCameraInterface>

@end
