//#-hidden-code
//This code is hidden as it is simply not that relevant for showcasing CoreML.
import UIKit
import CoreVideo
import CoreML
import Vision
import Foundation
import AVFoundation
import Accelerate
import PlaygroundSupport


extension UIStackView {
    func addBackgroundLayer(color: UIColor) {
        let v = UIView()
        v.backgroundColor = color
        v.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        insertSubview(v, at: 0)
    }
}

typealias PredictionItem = (String, Double)

protocol ImageClassifier {
    
    func process(_ img: UIImage, callback: @escaping ([PredictionItem]?) -> Void)
    
}

enum CameraError: Error {
    case runtimeError(String)
}


//#-end-hidden-code
/*:
 [Previous](@previous)
 # Using the camera
 Now, when it comes to using the camera to process live images, things get a bit more complicated. This is not caused by the AI-related part of our implementation, but furthermore by the additional code required to run the camera. For this purpose, we will use _AVFoundation_ and create a dedicated class to run the camera. Please note: _We will reuse some of our existing code from the previous page. This, most notably, includes the PreditionItem typealias as well as the UIStackView extension. Additionally, our entry point view controller from the previous page is also included and will be reused here._
 */
protocol CameraDelegate: class {
    func captured(frame: CVPixelBuffer?, timestamp: CMTime, camera: Camera)
}

class Camera : NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var delegate: CameraDelegate?
    var session: AVCaptureSession? = nil
    var camera: AVCaptureDevice? = nil
    var preview: AVCaptureVideoPreviewLayer? = nil
    let queue = DispatchQueue(label: "de.fheuschen.camque")
    let output = AVCaptureVideoDataOutput()
    
    init(_ delegate: CameraDelegate) {
        self.delegate = delegate
    }
    
    func prepareCamera(complete: @escaping (Error?) -> Void) {
        
        func initSession() {
            self.session = AVCaptureSession()
        }
        
        func configure() throws {
            self.session?.beginConfiguration()
            self.session?.sessionPreset = .hd1280x720
            guard let cam = AVCaptureDevice.default(for: .video) else {
                throw CameraError.runtimeError("Seems like this device doesn't have a camera. Are you running on a Simulator?")
            }
            self.camera = cam
            guard let input = try? AVCaptureDeviceInput(device: self.camera!) else {
                fatalError("Could not create camera input!")
            }
            if(session!.canAddInput(input)) {
                session?.addInput(input)
            }
            output.setSampleBufferDelegate(self, queue: queue)
            output.alwaysDiscardsLateVideoFrames = true
            output.connection(with: .video)?.videoOrientation = .portrait
            if(self.session!.canAddOutput(output)) {
                self.session!.addOutput(output)
            }
            self.preview = {
                let prev = AVCaptureVideoPreviewLayer(session: self.session!)
                prev.videoGravity = .resizeAspect
                prev.connection?.videoOrientation = .landscapeLeft
                return prev
            }()
            
            let dimensions = CMVideoFormatDescriptionGetDimensions(self.camera!.activeFormat.formatDescription)
            for format in self.camera!.formats {
                let fdimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let ranges = format.videoSupportedFrameRateRanges as [AVFrameRateRange]
                if let frameRate = ranges.first,
                     frameRate.maxFrameRate >= Float64(30) &&
                     frameRate.minFrameRate <= Float64(30) &&
                     dimensions.width == fdimensions.width &&
                     dimensions.height == fdimensions.height &&
                     CMFormatDescriptionGetMediaSubType(format.formatDescription) == 875704422 {
                    do {
                        try self.camera!.lockForConfiguration()
                      self.camera!.activeFormat = format as AVCaptureDevice.Format
                      self.camera!.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(30))
                      self.camera!.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(0))
                      self.camera!.unlockForConfiguration()
                      break
                    } catch {
                      continue
                    }
                  }
                
            }
            
            self.session?.commitConfiguration()
        }
        
        queue.async {
            do {
                initSession()
                try configure()
            } catch {
                complete(error)
                return
            }
            
            DispatchQueue.main.async {
                complete(nil)
            }
        }
    }
    
    /// Updates the output orientation to the given value. Moreover, this updates the orientation of the processed image to prevent wrong predictions due to rotated images.
    func updateImageOrientation(_ orientation: AVCaptureVideoOrientation)
    {
        self.preview?.connection?.videoOrientation = orientation
        self.output.connection(with: .video)?.videoOrientation = orientation
    }
    
    //#-hidden-code
    func startCamera() {
        if !self.session!.isRunning {
            self.session!.startRunning()
        }
    }
    
    func stopCamera() {
        if self.session!.isRunning {
            self.session!.stopRunning()
        }
    }
    
    //#-end-hidden-code 
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        delegate?.captured(frame: CMSampleBufferGetImageBuffer(sampleBuffer), timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), camera: self)
    }
    
}

/*:
 # The camera view
 Of course, we want our users to see on what base (i.e., which image) the prediction they see was made. The best and user-friendliest way for this, in my opinion, is to simply show a live camera view. Therefore, the following class contains the code for the preview and - again - the actual magic. Here we use _Vision_ as our default prediction provider, but maybe __you__ can complete the _doPredictionCoreML_ method using the knowledge you gained in the first chapter. _Have fun ;)_!
 Note: **Unfortunately, it seems to be impossible to get the correct device orientation within Swift Playgrounds. Though I can calculate if the device is in landscape or portrait mode, I cannot say whether it is _landscapeLeft_ or _landscapeRight_. Therefore, I hardcoded _landscapeLeft_ which means that you have to hold your iPad in landscape mode with the lightning port on your left-hand side or in portrait mode with the lightning port to the bottom!**
 */

//#-hidden-code

extension UIImage {
    
    func convertToCVPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        
        var pb: CVPixelBuffer?
        
        let pbAttributeDict = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
        kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue]
        
        let stat = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, pbAttributeDict as CFDictionary, &pb)
        
        if(stat != kCVReturnSuccess || pb == nil) {
            return nil //failed to create pixel buffer
        }
        
        CVPixelBufferLockBaseAddress(pb!, CVPixelBufferLockFlags(rawValue: 0))
        let data = CVPixelBufferGetBaseAddress(pb!)
        
        guard let context = CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            return nil //Failed either
        }
        
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        
        UIGraphicsPushContext(context)
        self.draw(in: CGRect(x: 0, y: 0, width: width, height: height)) //Draw using pushed context
        UIGraphicsPopContext() //Pop context
        
        CVPixelBufferUnlockBaseAddress(pb!, CVPixelBufferLockFlags(rawValue: 0))
        
        return pb!
    }
    
    func scaleTo(_ size: CGFloat) -> UIImage {
        
        let ratio = self.size.width / self.size.height
        var newWidth: CGFloat, newHeight: CGFloat
        
        if(self.size.width > self.size.height) {
            newHeight = size
            newWidth = round(size * ratio)
        } else {
            newWidth = size
            newHeight = round(size * ratio)
        }
        
        let nS = CGSize(width: newWidth, height: newHeight)
        
        UIGraphicsBeginImageContextWithOptions(nS, false, 0.0)
        self.draw(in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let scaled = UIGraphicsGetImageFromCurrentImageContext() else {
            fatalError("Could not scale image!")
        }
        UIGraphicsEndImageContext()
        return scaled
    }
    
}

extension CVPixelBuffer {
    
    func scaleAndCropPixelBufferTo(_ size: CGFloat) -> CVPixelBuffer? {
        autoreleasepool {
            var image: UIImage? = UIImage(ciImage: CIImage(cvPixelBuffer: self))
            var img: UIImage? = image!.scaleTo(size) // First of all, we scale down the image to something around 224x224 pixels (keeping aspect ratio!).
            let buf = img!.convertToCVPixelBuffer(width: Int(size), height: Int(size)) // Second of all, we create the neccessary CVPixelBuffer as described above.
            image = nil
            img = nil
            return buf!
        }
    }
    
}

//#-end-hidden-code

class CameraViewController : UIViewController, CameraDelegate {
    
    let dispatchSemaphore = DispatchSemaphore(value: 3)
    let model = MobileNetV2FP16()
    
    var requestStore = [VNCoreMLRequest]()
    var i = 0
    
    var plainCoreML = false
    let queue = DispatchQueue(label: "de.fheuschen.camque.live")
    
    
    var parsedPredictions = UILabel()
    weak var camera: Camera? = nil
    var video: UIView = UIView()
/*:
In this method, we initialize our _VNCoreMLModel_ as well as three _VNCoreMLRequests_ which we store in our request store array. These requests will later be reused by our code.
*/
    func initialize(_ cam: Camera) {
        guard let vM = try? VNCoreMLModel(for: self.model.model) else {
            fatalError("Could not create Vision Model!")
        }
        for _ in 0...3 {
            requestStore.append({
                let r = VNCoreMLRequest(model: vM, completionHandler: handlePrediction(req:error:))
                r.imageCropAndScaleOption = .centerCrop
                    return r
            }())
        }
        
        //#-hidden-code
        guard let videoView = cam.preview else {
            fatalError("Could not get camera preview!")
        }
        self.video.layer.insertSublayer(videoView, at: 0)
        cam.preview?.frame = self.video.bounds

        self.camera = cam
        //#-end-hidden-code
        
        //[...]
    }
    
    override func loadView() {
        
        //#-hidden-code
        self.parsedPredictions.textAlignment = .center
        self.view = self.video
        self.camera!.preview?.frame = self.video.bounds
        //#-end-hidden-code
        
        //[...]
    }
    
    override func viewDidLoad() {
        title = "Live"
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.camera!.stopCamera()
    }
    var vibrancy = UIVisualEffectView(), blur = UIVisualEffectView()
    override func viewWillAppear(_ animated: Bool) {
        
        //#-hidden-code
        let blurEffect = UIBlurEffect(style: .regular)
        let blurEffectView = UIVisualEffectView(effect: blurEffect)
        view.addSubview(blurEffectView)
        let vibrancyEffect = UIVibrancyEffect(blurEffect: blurEffect)
        let vibrancyEffectView = UIVisualEffectView(effect: vibrancyEffect)
        self.parsedPredictions = UILabel(frame: CGRect(x: 0, y: 0, width: self.view.frame.width, height: 80))
        self.parsedPredictions.text = "No prediction avail."
        self.parsedPredictions.textAlignment = .center
        self.parsedPredictions.lineBreakMode = .byWordWrapping
        self.parsedPredictions.numberOfLines = 0
        vibrancyEffectView.contentView.addSubview(parsedPredictions)
        blurEffectView.contentView.addSubview(vibrancyEffectView)
        blurEffectView.frame = CGRect(x: 0, y: 0, width: self.view.frame.width, height: 80)
        vibrancyEffectView.frame = CGRect(x: 0, y: 0, width: self.view.frame.width, height: 80)
        vibrancyEffectView.alpha = 0.5
        //#-end-hidden-code
        
        //[...]
        self.vibrancy = vibrancyEffectView
        self.blur = blurEffectView
    }
    
    override func viewWillLayoutSubviews() {
        self.camera!.preview?.frame = self.video.bounds
        self.vibrancy.frame = CGRect(x: 0, y: 0, width: self.view.frame.width, height: 80)
        self.blur.frame = CGRect(x: 0, y: 0, width: self.view.frame.width, height: 80)
        self.parsedPredictions.frame = CGRect(x: 0, y: 0, width: self.view.frame.width, height: 80)
        if(self.isLandscape(self.view.frame))
        {
            /*
             In the Swift Playgrounds app the live view is shown in portrait mode when the iPad is in landscape mode and vice versa. Therefore, we have to choose the respective opposite option to make it work in Playgrounds (otherwise, the shown preview would be upside-down or similar). In a normal app, we'd do it the normal way.
             */
            self.camera!.updateImageOrientation(.portrait)
        } else {
            self.camera!.updateImageOrientation(.landscapeLeft)
        }
    }
    
    internal func isLandscape(_ frame: CGRect) -> Bool {
        return frame.width > frame.height && frame.height != 0
    }
    
    //#-hidden-code
    override var shouldAutorotate: Bool {
        return false
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }
    
    @objc
    func exit() {
        self.navigationController?.popViewController(animated: true)
    }
    //#-end-hidden-code
    
/*:
## Using Vision
 As we can see here, the Vision implementation for this is very simple. We simply have to get a request object and execute it on a handler with our pixel buffer. It couldn't be easier, right?
 */
    func doPrediction(_ pb: CVPixelBuffer) {
        //#-editable-code
        let req = requestStore[i]
        let handler = VNImageRequestHandler(cvPixelBuffer: pb)
        
        i = ((i + 1 > 3) ? 0 : i + 1)
        
        queue.async {
            try? handler.perform([req])
        }
        //#-end-editable-code
    }

   func captured(frame: CVPixelBuffer?, timestamp: CMTime, camera: Camera) {
       if(frame == nil) {
           return
       }
       self.dispatchSemaphore.wait()
       self.doPrediction(frame!)
   }
    
/*:
 Here we get the results from the Vision implementation. We just fetch the classifications from the request and pass it to the _showPrediction_ method below.
 */
    func handlePrediction(req: VNRequest, error: Error?) {
        
        guard let classification = req.results as? [VNClassificationObservation] else {
            self.dispatchSemaphore.signal()
            return
        }
        
        DispatchQueue.main.async {
            self.showPrediction(classification.prefix(through: 4).map({
                ($0.identifier, Double($0.confidence))
            }))
        }
        
        self.dispatchSemaphore.signal()
        
    }
    
/*:
 This method simply displays the results from both implementations.
 */
    func showPrediction(_ predictions: [PredictionItem]) {
        var labeling = ""
        var n = 1
        for p in predictions {
            labeling += p.0 + ": " + String(round((p.1 * 100) * 1000) / 1000) + "%\n"
            if(n > 5) {
                break
            }
            n += 1
        }
        self.parsedPredictions.text = labeling
    }
    

    
}

/*:
 # The UI Stuff - again
 This class - again - contains the entry point UI for this page. As this is relatively self-explanatory, we can just skip this section (though I've already hidden parts of this class, I didn't want to leave it out completely as it contains the code that results in the camera start).
 */

class ViewController : UIViewController {
    
    let stackView = UIStackView()
    let startCamera = UIButton(type: .system)
    var classifier: ImageClassifier? = nil
    var camera: Camera? = nil
    var running = false
    var cameraViewController: CameraViewController?
    
    override func loadView() {
        super.loadView()
        //#-hidden-code
        //self.stackView.addBackgroundLayer(color: .white)
        self.stackView.axis = .horizontal
        self.stackView.distribution = .fillEqually
        self.stackView.alignment = .center
        self.startCamera.setTitle("Start camera", for: .normal)
        self.stackView.addArrangedSubview(self.startCamera)
        //#-end-hidden-code
        self.view = stackView
        self.startCamera.addTarget(self, action: #selector(start), for: .touchUpInside)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        //#-hidden-code
        self.title = "Click to open the camera"
        self.navigationController?.navigationBar.isTranslucent = false
        
        
        switch traitCollection.userInterfaceStyle {
            case .light, .unspecified:
                self.stackView.addBackgroundLayer(color: .white)
                self.navigationController?.navigationBar.backgroundColor = .white
            case .dark:
                self.stackView.addBackgroundLayer(color: .black)
                self.navigationController?.navigationBar.backgroundColor = .black
        }
        self.navigationController?.navigationBar.backItem?.backBarButtonItem = UIBarButtonItem(title: "Back", style: .plain, target: nil, action: nil)
        self.edgesForExtendedLayout = .all
        
        self.startCamera.center = CGPoint(x: 0, y: 0)
        UIView.animate(withDuration: 0.75, delay: 0.0, options: [.curveEaseInOut], animations: {
            self.startCamera.center = CGPoint(x: 50, y: 0)
        })
        
        //#-end-hidden-code
        //[...]
    }
    
    //#-hidden-code
    override func viewWillAppear(_ animated: Bool) {
        if(!isBeingPresented && !isMovingToParent && view.window != nil) {
            self.running = false
        }
    }
    //#-end-hidden-code
    
    @objc
    func start() {
        self.cameraViewController = CameraViewController()
        self.camera = Camera(self.cameraViewController!)
        self.camera?.prepareCamera(complete: {
            error in
            if(error == nil) {
                print("Sucessfully prepared camera.")
                self.camera?.startCamera()
                self.cameraViewController?.initialize(self.camera!)
                self.running = true
                self.navigationController?.pushViewController(self.cameraViewController!, animated: true)
            } else {
                print(error!)
            }
        })
    }
    
}

//#-hidden-code
NSSetUncaughtExceptionHandler { exception in
    print("An exception was thrown: \(exception). This is not intended to happen.")
}
//#-end-hidden-code

/*:
  ## Last, but not least,...
 ... we have to show our view.
 */

PlaygroundPage.current.liveView = UINavigationController(rootViewController: ViewController())

/*:
## That's it!
 Wow - though this was already a bit more complicated than our previous example, we only needed about _600_ lines of code!
  As you will have noticed, this page only contained the Vision implementation. On the next page, you have the chance to implement the missing CoreML one yourself!
  [Next](@next)
 */
