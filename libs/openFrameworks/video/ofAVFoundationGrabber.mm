/*
 *  ofAVFoundationGrabber.mm
 */

#include "ofAVFoundationGrabber.h"
#include "ofVectorMath.h"
#include "ofRectangle.h"
#include "ofGLUtils.h"

#import <Accelerate/Accelerate.h>

@interface OSXVideoGrabber ()
@property (nonatomic,retain) AVCaptureSession *captureSession;
@end

@implementation OSXVideoGrabber
@synthesize captureSession;

#pragma mark -
#pragma mark Initialization
- (instancetype)init {
	self = [super init];
	if (self) {
		captureInput = nil;
		captureOutput = nil;
		device = nil;

		bInitCalled = NO;
		grabberPtr = NULL;
		deviceID = 0;
        width = 0;
        height = 0;
        currentFrame = 0;
	}
	return self;
}

- (BOOL)initCapture:(int)framerate capWidth:(int)w capHeight:(int)h{
	NSArray * devices;
	if (@available(macOS 10.15, *)) {
		AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[
			AVCaptureDeviceTypeBuiltInWideAngleCamera,
			AVCaptureDeviceTypeExternalUnknown,
		] mediaType:nil position:AVCaptureDevicePositionUnspecified];
		devices = [session devices];
	} else {
		devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
	}
	
	if([devices count] > 0) {
		if(deviceID>[devices count]-1)
			deviceID = [devices count]-1;


		// We set the device
		device = [devices objectAtIndex:deviceID];

		NSError *error = nil;
		[device lockForConfiguration:&error];

		if(!error) {

			float smallestDist = 99999999.0;
			int bestW, bestH = 0;

			// Set width and height to be passed in dimensions
			// We will then check to see if the dimensions are supported and if not find the closest matching size.
			width = w;
			height = h;

			glm::vec2 requestedDimension(width, height);

			AVCaptureDeviceFormat * bestFormat  = nullptr;
			for ( AVCaptureDeviceFormat * format in [device formats] ) {
				CMFormatDescriptionRef desc = format.formatDescription;
				CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(desc);

				int tw = dimensions.width;
				int th = dimensions.height;
                glm::vec2 formatDimension(tw, th);

				if( tw == width && th == height ){
					bestW = tw;
					bestH = th;
					bestFormat = format;
					break;
				}

				float dist = glm::length(formatDimension - requestedDimension);
				if( dist < smallestDist ){
					smallestDist = dist;
					bestW = tw;
					bestH = th;
					bestFormat = format;
				}

				ofLogVerbose("ofAvFoundationGrabber") << " supported dimensions are: " << dimensions.width << " " << dimensions.height;
			}

			// Set the new dimensions and format
			if( bestFormat != nullptr && bestW != 0 && bestH != 0 ){
				if( bestW != width || bestH != height ){
					ofLogWarning("ofAvFoundationGrabber") << " requested width and height aren't supported. Setting capture size to closest match: " << bestW << " by " << bestH<< std::endl;
				}

				[device setActiveFormat:bestFormat];
				width = bestW;
				height = bestH;
			}

			//only set the framerate if it has been set by the user
			if( framerate > 0 ){

				AVFrameRateRange * desiredRange = nil;
				NSArray * supportedFrameRates = device.activeFormat.videoSupportedFrameRateRanges;

				int numMatch = 0;
				for(AVFrameRateRange * range in supportedFrameRates){

					if( (std::floor(range.minFrameRate) <= framerate && std::ceil(range.maxFrameRate) >= framerate) ){
						ofLogVerbose("ofAvFoundationGrabber") << "found good framerate range, min: " << range.minFrameRate << " max: " << range.maxFrameRate << " for requested fps: " << framerate;
						desiredRange = range;
						numMatch++;
						fps = range.maxFrameRate;
					}
				}

				if( numMatch > 0 ){
					//TODO: this crashes on some devices ( Orbecc Astra Pro )
					device.activeVideoMinFrameDuration = desiredRange.minFrameDuration;
					device.activeVideoMaxFrameDuration = desiredRange.maxFrameDuration;
				}else{
					ofLogError("ofAvFoundationGrabber") << " could not set framerate to: " << framerate << ". Device supports: ";
					for(AVFrameRateRange * range in supportedFrameRates){
						ofLogError() << "  framerate range of: " << range.minFrameRate <<
					 " to " << range.maxFrameRate;
					 }
				}

			}

			[device unlockForConfiguration];
		} else {
			NSLog(@"OSXVideoGrabber Init Error: %@", error);
		}

		// We setup the input
		captureInput						= [AVCaptureDeviceInput
											   deviceInputWithDevice:device
											   error:nil];

		// We setup the output
		captureOutput = [[AVCaptureVideoDataOutput alloc] init];
		// While a frame is processes in -captureOutput:didOutputSampleBuffer:fromConnection: delegate methods no other frames are added in the queue.
		// If you don't want this behaviour set the property to NO
		captureOutput.alwaysDiscardsLateVideoFrames = YES;



		// We create a serial queue to handle the processing of our frames
		dispatch_queue_t queue;
		queue = dispatch_queue_create("cameraQueue", NULL);
		[captureOutput setSampleBufferDelegate:self queue:queue];

		NSDictionary* videoSettings =[NSDictionary dictionaryWithObjectsAndKeys:
                              [NSNumber numberWithDouble:width], (id)kCVPixelBufferWidthKey,
                              [NSNumber numberWithDouble:height], (id)kCVPixelBufferHeightKey,
                              [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA], (id)kCVPixelBufferPixelFormatTypeKey,
                              nil];
		[captureOutput setVideoSettings:videoSettings];

		// And we create a capture session
		if(self.captureSession) {
			self.captureSession = nil;
		}
		self.captureSession = [[AVCaptureSession alloc] init];

		[self.captureSession beginConfiguration];

		// We add input and output
		[self.captureSession addInput:captureInput];
		[self.captureSession addOutput:captureOutput];

		// We specify a minimum duration for each frame (play with this settings to avoid having too many frames waiting
		// in the queue because it can cause memory issues). It is similar to the inverse of the maximum framerate.
		// In this example we set a min frame duration of 1/10 seconds so a maximum framerate of 10fps. We say that
		// we are not able to process more than 10 frames per second.
		// Called after added to captureSession

		AVCaptureConnection *conn = [captureOutput connectionWithMediaType:AVMediaTypeVideo];
		if ([conn isVideoMinFrameDurationSupported] == YES &&
			[conn isVideoMaxFrameDurationSupported] == YES) {
				[conn setVideoMinFrameDuration:CMTimeMake(1, framerate)];
				[conn setVideoMaxFrameDuration:CMTimeMake(1, framerate)];
		}

		// We start the capture Session
		[self.captureSession commitConfiguration];
		[self.captureSession startRunning];

		bInitCalled = YES;
		return YES;
	}
	return NO;
}

-(void) startCapture{

	[self.captureSession startRunning];

	[captureInput.device lockForConfiguration:nil];

	//if( [captureInput.device isExposureModeSupported:AVCaptureExposureModeAutoExpose] ) [captureInput.device setExposureMode:AVCaptureExposureModeAutoExpose ];
	if( [captureInput.device isFocusModeSupported:AVCaptureFocusModeAutoFocus] )	[captureInput.device setFocusMode:AVCaptureFocusModeAutoFocus ];

}

-(void) lockExposureAndFocus{

	[captureInput.device lockForConfiguration:nil];

	//if( [captureInput.device isExposureModeSupported:AVCaptureExposureModeLocked] ) [captureInput.device setExposureMode:AVCaptureExposureModeLocked ];
	if( [captureInput.device isFocusModeSupported:AVCaptureFocusModeLocked] )	[captureInput.device setFocusMode:AVCaptureFocusModeLocked ];


}

-(void)stopCapture{
	if(self.captureSession) {
		if(captureOutput){
			if(captureOutput.sampleBufferDelegate != nil) {
				[captureOutput setSampleBufferDelegate:nil queue:NULL];
			}
		}

		// remove the input and outputs from session
		for(AVCaptureInput *input1 in self.captureSession.inputs) {
		    [self.captureSession removeInput:input1];
		}
		for(AVCaptureOutput *output1 in self.captureSession.outputs) {
		    [self.captureSession removeOutput:output1];
		}

		[self.captureSession stopRunning];
	}
}

-(CGImageRef)getCurrentFrame{
	return currentFrame;
}

-(std::vector <ofVideoDevice>)listDevices{
    std::vector <ofVideoDevice> deviceList;

	NSArray * devices;
	if (@available(macOS 10.15, *)) {
		AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[
			AVCaptureDeviceTypeBuiltInWideAngleCamera,
			AVCaptureDeviceTypeExternalUnknown,
		] mediaType:nil position:AVCaptureDevicePositionUnspecified];
		devices = [session devices];
	} else {
		devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
	}

	int i=0;
	for (AVCaptureDevice * captureDevice in devices){
        ofVideoDevice vd;
        vd.id = i;
        vd.deviceName = [captureDevice.localizedName UTF8String];
        vd.bAvailable = true;

		ofLogNotice() << "Device: " << i << ": " << vd.deviceName;

        ofLogNotice() << "  Supported formats:";
        for ( AVCaptureDeviceFormat *format in [captureDevice formats] ) {

            CMFormatDescriptionRef desc = format.formatDescription;
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(desc);
            CMVideoCodecType codec = CMVideoFormatDescriptionGetCodecType(desc);

            std::string codecName;
            switch(codec){
                case kCVPixelFormatType_1Monochrome: codecName = "1Monochrome"; break;
                case kCVPixelFormatType_2Indexed: codecName = "2Indexed"; break;
                case kCVPixelFormatType_4Indexed: codecName = "4Indexed"; break;
                case kCVPixelFormatType_8Indexed: codecName = "8Indexed"; break;
                case kCVPixelFormatType_1IndexedGray_WhiteIsZero: codecName = "1IndexedGray_WhiteIsZero"; break;
                case kCVPixelFormatType_2IndexedGray_WhiteIsZero: codecName = "2IndexedGray_WhiteIsZero"; break;
                case kCVPixelFormatType_4IndexedGray_WhiteIsZero: codecName = "4IndexedGray_WhiteIsZero"; break;
                case kCVPixelFormatType_8IndexedGray_WhiteIsZero: codecName = "8IndexedGray_WhiteIsZero"; break;
                case kCVPixelFormatType_16BE555: codecName = "16BE555"; break;
                case kCVPixelFormatType_16LE555: codecName = "16LE555"; break;
                case kCVPixelFormatType_16LE5551: codecName = "16LE5551"; break;
                case kCVPixelFormatType_16BE565: codecName = "16BE565"; break;
                case kCVPixelFormatType_16LE565: codecName = "16LE565"; break;
                case kCVPixelFormatType_24RGB: codecName = "24RGB"; break;
                case kCVPixelFormatType_24BGR: codecName = "24BGR"; break;
                case kCVPixelFormatType_32ARGB: codecName = "32ARGB"; break;
                case kCVPixelFormatType_32BGRA: codecName = "32BGRA"; break;
                case kCVPixelFormatType_32ABGR: codecName = "32ABGR"; break;
                case kCVPixelFormatType_32RGBA: codecName = "32RGBA"; break;
                case kCVPixelFormatType_64ARGB: codecName = "64ARGB"; break;
                case kCVPixelFormatType_64RGBALE: codecName = "64RGBALE"; break;
                case kCVPixelFormatType_48RGB: codecName = "48RGB"; break;
                case kCVPixelFormatType_32AlphaGray: codecName = "32AlphaGray"; break;
                case kCVPixelFormatType_16Gray: codecName = "16Gray"; break;
                case kCVPixelFormatType_30RGB: codecName = "30RGB"; break;
                case kCVPixelFormatType_422YpCbCr8: codecName = "422YpCbCr8"; break;
                case kCVPixelFormatType_4444YpCbCrA8: codecName = "4444YpCbCrA8"; break;
                case kCVPixelFormatType_4444YpCbCrA8R: codecName = "4444YpCbCrA8R"; break;
                case kCVPixelFormatType_4444AYpCbCr8: codecName = "4444AYpCbCr8"; break;
                case kCVPixelFormatType_4444AYpCbCr16: codecName = "4444AYpCbCr16"; break;
                case kCVPixelFormatType_4444AYpCbCrFloat: codecName = "4444AYpCbCrFloat"; break;
                case kCVPixelFormatType_444YpCbCr8: codecName = "444YpCbCr8"; break;
                case kCVPixelFormatType_422YpCbCr16: codecName = "422YpCbCr16"; break;
                case kCVPixelFormatType_422YpCbCr10: codecName = "422YpCbCr10"; break;
                case kCVPixelFormatType_444YpCbCr10: codecName = "444YpCbCr10"; break;
                case kCVPixelFormatType_420YpCbCr8Planar: codecName = "420YpCbCr8Planar"; break;
                case kCVPixelFormatType_420YpCbCr8PlanarFullRange: codecName = "420YpCbCr8PlanarFullRange"; break;
                case kCVPixelFormatType_422YpCbCr_4A_8BiPlanar: codecName = "422YpCbCr_4A_8BiPlanar"; break;
                case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: codecName = "420YpCbCr8BiPlanarVideoRange"; break;
                case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: codecName = "420YpCbCr8BiPlanarFullRange"; break;
                case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange: codecName = "422YpCbCr8BiPlanarVideoRange"; break;
                case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange: codecName = "422YpCbCr8BiPlanarFullRange"; break;
                case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: codecName = "444YpCbCr8BiPlanarVideoRange"; break;
                case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: codecName = "444YpCbCr8BiPlanarFullRange"; break;
                case kCVPixelFormatType_422YpCbCr8_yuvs: codecName = "422YpCbCr8_yuvs"; break;
                case kCVPixelFormatType_422YpCbCr8FullRange: codecName = "422YpCbCr8FullRange"; break;
                case kCVPixelFormatType_OneComponent8: codecName = "OneComponent8"; break;
                case kCVPixelFormatType_TwoComponent8: codecName = "TwoComponent8"; break;
                case kCVPixelFormatType_30RGBLEPackedWideGamut: codecName = "30RGBLEPackedWideGamut"; break;
                case kCVPixelFormatType_ARGB2101010LEPacked: codecName = "ARGB2101010LEPacked"; break;
                case kCVPixelFormatType_40ARGBLEWideGamut: codecName = "40ARGBLEWideGamut"; break;
                case kCVPixelFormatType_40ARGBLEWideGamutPremultiplied: codecName = "40ARGBLEWideGamutPremultiplied"; break;
                case kCVPixelFormatType_OneComponent10: codecName = "OneComponent10"; break;
                case kCVPixelFormatType_OneComponent12: codecName = "OneComponent12"; break;
                case kCVPixelFormatType_OneComponent16: codecName = "OneComponent16"; break;
                case kCVPixelFormatType_TwoComponent16: codecName = "TwoComponent16"; break;
                case kCVPixelFormatType_OneComponent16Half: codecName = "OneComponent16Half"; break;
                case kCVPixelFormatType_OneComponent32Float: codecName = "OneComponent32Float"; break;
                case kCVPixelFormatType_TwoComponent16Half: codecName = "TwoComponent16Half"; break;
                case kCVPixelFormatType_TwoComponent32Float: codecName = "TwoComponent32Float"; break;
                case kCVPixelFormatType_64RGBAHalf: codecName = "64RGBAHalf"; break;
                case kCVPixelFormatType_128RGBAFloat: codecName = "128RGBAFloat"; break;
                case kCVPixelFormatType_14Bayer_GRBG: codecName = "14Bayer_GRBG"; break;
                case kCVPixelFormatType_14Bayer_RGGB: codecName = "14Bayer_RGGB"; break;
                case kCVPixelFormatType_14Bayer_BGGR: codecName = "14Bayer_BGGR"; break;
                case kCVPixelFormatType_14Bayer_GBRG: codecName = "14Bayer_GBRG"; break;
                case kCVPixelFormatType_DisparityFloat16: codecName = "DisparityFloat16"; break;
                case kCVPixelFormatType_DisparityFloat32: codecName = "DisparityFloat32"; break;
                case kCVPixelFormatType_DepthFloat16: codecName = "DepthFloat16"; break;
                case kCVPixelFormatType_DepthFloat32: codecName = "DepthFloat32"; break;
                case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: codecName = "420YpCbCr10BiPlanarVideoRange"; break;
                case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: codecName = "422YpCbCr10BiPlanarVideoRange"; break;
                case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: codecName = "444YpCbCr10BiPlanarVideoRange"; break;
                case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: codecName = "420YpCbCr10BiPlanarFullRange"; break;
                case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: codecName = "422YpCbCr10BiPlanarFullRange"; break;
                case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: codecName = "444YpCbCr10BiPlanarFullRange"; break;
                case kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar: codecName = "420YpCbCr8VideoRange_8A_TriPlanar"; break;
                case kCVPixelFormatType_16VersatileBayer: codecName = "16VersatileBayer"; break;
                case kCVPixelFormatType_64RGBA_DownscaledProResRAW: codecName = "64RGBA_DownscaledProResRAW"; break;
                case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange: codecName = "422YpCbCr16BiPlanarVideoRange"; break;
                case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange: codecName = "444YpCbCr16BiPlanarVideoRange"; break;
                case kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar: codecName = "444YpCbCr16VideoRange_16A_TriPlanar"; break;
                default: codecName = "unknown"; break;
            }

            std::stringstream ss;
            ss << "  " << std::left << std::setw(32) <<  codecName <<  ": "
            << std::right
            << std::setfill(' ')<< std::setw(4) << dimensions.width << " x "
            << std::setfill(' ')<< std::setw(4) << dimensions.height << "px, ";

            ofVideoFormat vf;
            vf.width = dimensions.width;
            vf.height = dimensions.height;
            vf.videoCodec.codec = codec;
            vf.videoCodec.name = codecName;

            ss << "fps: ";

            for ( AVFrameRateRange *range in format.videoSupportedFrameRateRanges ) {
                if(range.minFrameRate == range.maxFrameRate){
                    // Some device (like logitech webcam) gives range that has same min and max value like {30-30, 24-24, 20-20, ...}.
                    // In this case we only store minFrameRate.
                    vf.framerates.push_back(range.minFrameRate);
                    ss << range.minFrameRate << ", ";
                }else{
                    // But Some device (like macbook pro's webcam) gives range like {15-30}
                    // Not sure if we can get actual supported frame rates for this case.
                    vf.framerates.push_back(range.minFrameRate);
                    vf.framerates.push_back(range.maxFrameRate);
                    ss << range.minFrameRate << " - " << range.maxFrameRate << ", ";
                }
            }

            ofLogNotice() << ss.str().substr(0, ss.str().size()-2);
            vd.formats.push_back(vf);
        }

        deviceList.push_back(vd);

        // Get more information about the format
        // FourCharCode subtype = CMFormatDescriptionGetMediaSubType(desc);
        // CFDictionaryRef dict = CVPixelFormatDescriptionCreateWithPixelFormatType(NULL, subtype);
        // int bits = [[dict objectForKey:@"BitsPerComponent"] intValue];
        // bool bAlpha = [[dict objectForKey:@"ContainsAlpha"]boolValue];
        // bool bGray = [[dict objectForKey:@"ContainsGrayscale"]boolValue];
        // bool bRGB = [[dict objectForKey:@"ContainsRGB"]boolValue];
        // bool bYCvCr = [[dict objectForKey:@"ContainsYCbCr"]boolValue];
		i++;
    }
    return deviceList;
}

-(void)setDevice:(int)_device{
	deviceID = _device;
}

#pragma mark -
#pragma mark AVCaptureSession delegate
- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
	   fromConnection:(AVCaptureConnection *)connection
{
	if(grabberPtr != NULL) {
		@autoreleasepool {
			CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
			// Lock the image buffer
			CVPixelBufferLockBaseAddress(imageBuffer,0);

			if( grabberPtr != NULL && !grabberPtr->bLock ){

				unsigned char *isrc4 = (unsigned char *)CVPixelBufferGetBaseAddress(imageBuffer);
				size_t widthIn  = CVPixelBufferGetWidth(imageBuffer);
				size_t heightIn	= CVPixelBufferGetHeight(imageBuffer);

				if( widthIn != grabberPtr->getWidth() || heightIn != grabberPtr->getHeight() ){
					ofLogError("ofAVFoundationGrabber") << " incoming image dimensions " << widthIn << " by " << heightIn << " don't match. This shouldn't happen! Returning.";
					return;
				}

				if( grabberPtr->pixelFormat == OF_PIXELS_BGRA ){

					if( grabberPtr->capMutex.try_lock() ){
						grabberPtr->pixelsTmp.setFromPixels(isrc4, widthIn, heightIn, 4);
						grabberPtr->updatePixelsCB();
						grabberPtr->capMutex.unlock();
					}

				}else{

					ofPixels rgbConvertPixels;
					rgbConvertPixels.allocate(widthIn, heightIn, 3);

					vImage_Buffer srcImg;
					srcImg.width = widthIn;
					srcImg.height = heightIn;
					srcImg.data = isrc4;
					srcImg.rowBytes = CVPixelBufferGetBytesPerRow(imageBuffer);

					vImage_Buffer dstImg;
					dstImg.width = srcImg.width;
					dstImg.height = srcImg.height;
					dstImg.rowBytes = width*3;
					dstImg.data = rgbConvertPixels.getData();

					vImage_Error err;
					err = vImageConvert_BGRA8888toRGB888(&srcImg, &dstImg, kvImageNoFlags);
					if(err != kvImageNoError){
						ofLogError("ofAVFoundationGrabber") << "Error using accelerate to convert bgra to rgb with vImageConvert_BGRA8888toRGB888 error: " << err;
					}else{

						if( grabberPtr->capMutex.try_lock() ){
							grabberPtr->pixelsTmp = rgbConvertPixels;
							grabberPtr->updatePixelsCB();
							grabberPtr->capMutex.unlock();
						}

					}
				}

			// Unlock the image buffer
			CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

			}
		}
	}
}

#pragma mark -
#pragma mark Memory management

- (void)dealloc {
	// Stop the CaptureSession
	if(self.captureSession) {
		[self stopCapture];
		self.captureSession = nil;
	}
	if(captureOutput){
		if(captureOutput.sampleBufferDelegate != nil) {
			[captureOutput setSampleBufferDelegate:nil queue:NULL];
		}
		captureOutput = nil;
	}

	captureInput = nil;
	device = nil;

	if(grabberPtr) {
		[self eraseGrabberPtr];
	}
	grabberPtr = nil;
	if(currentFrame) {
		// release the currentFrame image
		CGImageRelease(currentFrame);
		currentFrame = nil;
	}
}

- (void)eraseGrabberPtr {
	grabberPtr = NULL;
}

@end


ofAVFoundationGrabber::ofAVFoundationGrabber(){
	fps		= -1;
	grabber = [[OSXVideoGrabber alloc] init];
    width = 0;
    height = 0;
	bIsInit = false;
	pixelFormat = OF_PIXELS_RGB;
	newFrame = false;
	bHavePixelsChanged = false;
	bLock = false;
}

ofAVFoundationGrabber::~ofAVFoundationGrabber(){
	ofLog(OF_LOG_VERBOSE, "ofAVFoundationGrabber destructor");
	close();
}

void ofAVFoundationGrabber::clear(){
	if( pixels.size() ){
		pixels.clear();
		pixelsTmp.clear();
	}
}

void ofAVFoundationGrabber::close(){
	bLock = true;
	if(grabber) {
		// Stop and release the the OSXVideoGrabber
		[grabber stopCapture];
		[grabber eraseGrabberPtr];
		grabber = nil;
	}
	clear();
	bIsInit = false;
	width = 0;
    height = 0;
	fps		= -1;
	pixelFormat = OF_PIXELS_RGB;
	newFrame = false;
	bHavePixelsChanged = false;
	bLock = false;
}

void ofAVFoundationGrabber::setDesiredFrameRate(int capRate){
	fps = capRate;
}

bool ofAVFoundationGrabber::setup(int w, int h){

	if( grabber == nil ){
		grabber = [[OSXVideoGrabber alloc] init];
	}

	grabber->grabberPtr = this;

	if( [grabber initCapture:fps capWidth:w capHeight:h] ) {

		//update the pixel dimensions based on what the camera supports
		width = grabber->width;
		height = grabber->height;
		fps = grabber->fps;

		clear();

		pixels.allocate(width, height, pixelFormat);
		pixelsTmp.allocate(width, height, pixelFormat);

		[grabber startCapture];

		newFrame=false;
		bIsInit = true;

		return true;
	} else {
		return false;
	}
}


bool ofAVFoundationGrabber::isInitialized() const{
    return bIsInit;
}

void ofAVFoundationGrabber::update(){
	newFrame = false;

	if (bHavePixelsChanged == true){
		capMutex.lock();
			pixels = pixelsTmp;
			bHavePixelsChanged = false;
		capMutex.unlock();
		newFrame = true;
	}
}

ofPixels & ofAVFoundationGrabber::getPixels(){
	return pixels;
}

const ofPixels & ofAVFoundationGrabber::getPixels() const{
	return pixels;
}

bool ofAVFoundationGrabber::isFrameNew() const{
	return newFrame;
}

void ofAVFoundationGrabber::updatePixelsCB(){
	//TODO: does this need a mutex? or some thread protection?
	bHavePixelsChanged = true;
}

std::vector <ofVideoDevice> ofAVFoundationGrabber::listDevices() const{
    return [grabber listDevices];
}

void ofAVFoundationGrabber::setDeviceID(int deviceID) {
	if( grabber == nil ){
		grabber = [[OSXVideoGrabber alloc] init];
	}
	[grabber setDevice:deviceID];
	device = deviceID;
}

bool ofAVFoundationGrabber::setPixelFormat(ofPixelFormat PixelFormat) {
	if(PixelFormat == OF_PIXELS_RGB){
		pixelFormat = PixelFormat;
		return true;
	} else if(PixelFormat == OF_PIXELS_RGBA){
		pixelFormat = PixelFormat;
		return true;
	} else if(PixelFormat == OF_PIXELS_BGRA){
		pixelFormat = PixelFormat;
		return true;
	}
	return false;
}

ofPixelFormat ofAVFoundationGrabber::getPixelFormat() const{
	return pixelFormat;
}
