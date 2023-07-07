import Foundation
import AVFoundation

@objc(QRScanner)
class QRScanner : CDVPlugin, AVCaptureMetadataOutputObjectsDelegate {
    
    class CameraView: UIView {
        var videoPreviewLayer:AVCaptureVideoPreviewLayer?
        
        func interfaceOrientationToVideoOrientation(_ orientation : UIInterfaceOrientation) -> AVCaptureVideoOrientation {
            switch (orientation) {
            case UIInterfaceOrientation.portrait:
                return AVCaptureVideoOrientation.portrait;
            case UIInterfaceOrientation.portraitUpsideDown:
                return AVCaptureVideoOrientation.portraitUpsideDown;
            case UIInterfaceOrientation.landscapeLeft:
                return AVCaptureVideoOrientation.landscapeLeft;
            case UIInterfaceOrientation.landscapeRight:
                return AVCaptureVideoOrientation.landscapeRight;
            default:
                return AVCaptureVideoOrientation.portraitUpsideDown;
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews();
            if let sublayers = self.layer.sublayers {
                for layer in sublayers {
                    layer.frame = self.bounds;
                }
            }
            
            self.videoPreviewLayer?.connection?.videoOrientation = interfaceOrientationToVideoOrientation(UIApplication.shared.statusBarOrientation);
        }
        
        
        func addPreviewLayer(_ previewLayer:AVCaptureVideoPreviewLayer?) {
            previewLayer!.videoGravity = AVLayerVideoGravity.resizeAspectFill
            previewLayer!.frame = self.bounds
            self.layer.addSublayer(previewLayer!)
            self.videoPreviewLayer = previewLayer;
        }
        
        func removePreviewLayer() {
            if self.videoPreviewLayer != nil {
                self.videoPreviewLayer!.removeFromSuperlayer()
                self.videoPreviewLayer = nil
            }
        }
    }

    var cameraView: CameraView!
    var iciciDesignView: UIView = UIView()
    var captureSession:AVCaptureSession?
    var captureVideoPreviewLayer:AVCaptureVideoPreviewLayer?
    var metaOutput: AVCaptureMetadataOutput?

    var currentCamera: Int = 0;
    var frontCamera: AVCaptureDevice?
    var backCamera: AVCaptureDevice?

    var scanning: Bool = false
    var paused: Bool = false
    var nextScanningCommand: CDVInvokedUrlCommand?

    enum QRScannerError: Int32 {
        case unexpected_error = 0,
        camera_access_denied = 1,
        camera_access_restricted = 2,
        back_camera_unavailable = 3,
        front_camera_unavailable = 4,
        camera_unavailable = 5,
        scan_canceled = 6,
        light_unavailable = 7,
        open_settings_unavailable = 8
    }

    enum CaptureError: Error {
        case backCameraUnavailable
        case frontCameraUnavailable
        case couldNotCaptureInput(error: NSError)
    }

    enum LightError: Error {
        case torchUnavailable
    }

    override func pluginInitialize() {
        super.pluginInitialize()
        NotificationCenter.default.addObserver(self, selector: #selector(pageDidLoad), name: NSNotification.Name.CDVPageDidLoad, object: nil)
        self.cameraView = CameraView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height))
        self.cameraView.autoresizingMask = [.flexibleWidth, .flexibleHeight];
    }

    func sendErrorCode(command: CDVInvokedUrlCommand, error: QRScannerError){
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.rawValue)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }

    // utility method
    @objc func backgroundThread(delay: Double = 0.0, background: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        if #available(iOS 8.0, *) {
            DispatchQueue.global(qos: DispatchQoS.QoSClass.userInitiated).async {
                if (background != nil) {
                    background!()
                }
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + delay * Double(NSEC_PER_SEC)) {
                    if(completion != nil){
                        completion!()
                    }
                }
            }
        } else {
            // Fallback for iOS < 8.0
            if(background != nil){
                background!()
            }
            if(completion != nil){
                completion!()
            }
        }
    }

    @objc func prepScanner(command: CDVInvokedUrlCommand) -> Bool{
        let status = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
        if (status == AVAuthorizationStatus.restricted) {
            self.sendErrorCode(command: command, error: QRScannerError.camera_access_restricted)
            return false
        } else if status == AVAuthorizationStatus.denied {
            self.sendErrorCode(command: command, error: QRScannerError.camera_access_denied)
            return false
        }
        do {
            if (captureSession?.isRunning != true){
                cameraView.backgroundColor = UIColor.clear
                self.webView!.superview!.insertSubview(cameraView, belowSubview: self.webView!)
                let availableVideoDevices =  AVCaptureDevice.devices(for: AVMediaType.video)
                for device in availableVideoDevices {
                    if device.position == AVCaptureDevice.Position.back {
                        backCamera = device
                    }
                    else if device.position == AVCaptureDevice.Position.front {
                        frontCamera = device
                    }
                }
                // older iPods have no back camera
                if(backCamera == nil){
                    currentCamera = 1
                }
                let input: AVCaptureDeviceInput
                input = try self.createCaptureDeviceInput()
                captureSession = AVCaptureSession()
                captureSession!.addInput(input)
                metaOutput = AVCaptureMetadataOutput()
                captureSession!.addOutput(metaOutput!)
                metaOutput!.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                metaOutput!.metadataObjectTypes = [AVMetadataObject.ObjectType.qr]
                captureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession!)
                cameraView.addPreviewLayer(captureVideoPreviewLayer)
                captureSession!.startRunning()
            }
            return true
        } catch CaptureError.backCameraUnavailable {
            self.sendErrorCode(command: command, error: QRScannerError.back_camera_unavailable)
        } catch CaptureError.frontCameraUnavailable {
            self.sendErrorCode(command: command, error: QRScannerError.front_camera_unavailable)
        } catch CaptureError.couldNotCaptureInput(let error){
            print(error.localizedDescription)
            self.sendErrorCode(command: command, error: QRScannerError.camera_unavailable)
        } catch {
            self.sendErrorCode(command: command, error: QRScannerError.unexpected_error)
        }
        return false
    }

    @objc func createCaptureDeviceInput() throws -> AVCaptureDeviceInput {
        var captureDevice: AVCaptureDevice
        if(currentCamera == 0){
            if(backCamera != nil){
                captureDevice = backCamera!
            } else {
                throw CaptureError.backCameraUnavailable
            }
        } else {
            if(frontCamera != nil){
                captureDevice = frontCamera!
            } else {
                throw CaptureError.frontCameraUnavailable
            }
        }
        let captureDeviceInput: AVCaptureDeviceInput
        do {
            captureDeviceInput = try AVCaptureDeviceInput(device: captureDevice)
        } catch let error as NSError {
            throw CaptureError.couldNotCaptureInput(error: error)
        }
        return captureDeviceInput
    }

    @objc func makeOpaque(){
        self.webView?.isOpaque = false
        self.webView?.backgroundColor = UIColor.clear
    }

    @objc func boolToNumberString(bool: Bool) -> String{
        if(bool) {
            return "1"
        } else {
            return "0"
        }
    }

    @objc func configureLight(command: CDVInvokedUrlCommand, state: Bool){
        var useMode = AVCaptureDevice.TorchMode.on
        if(state == false){
            useMode = AVCaptureDevice.TorchMode.off
        }
        do {
            // torch is only available for back camera
            if(backCamera == nil || backCamera!.hasTorch == false || backCamera!.isTorchAvailable == false || backCamera!.isTorchModeSupported(useMode) == false){
                throw LightError.torchUnavailable
            }
            try backCamera!.lockForConfiguration()
            backCamera!.torchMode = useMode
            backCamera!.unlockForConfiguration()
            self.getStatus(command)
        } catch LightError.torchUnavailable {
            self.sendErrorCode(command: command, error: QRScannerError.light_unavailable)
        } catch let error as NSError {
            print(error.localizedDescription)
            self.sendErrorCode(command: command, error: QRScannerError.unexpected_error)
        }
    }

    // This method processes metadataObjects captured by iOS.
    func metadataOutput(_ captureOutput: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if metadataObjects.count == 0 || scanning == false {
            // while nothing is detected, or if scanning is false, do nothing.
            return
        }
        let found = metadataObjects[0] as! AVMetadataMachineReadableCodeObject
        if found.type == AVMetadataObject.ObjectType.qr && found.stringValue != nil {
            scanning = false
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: found.stringValue)
            commandDelegate!.send(pluginResult, callbackId: nextScanningCommand?.callbackId!)
            nextScanningCommand = nil
        }
    }

    @objc func pageDidLoad() {
        self.webView?.isOpaque = false
        self.webView?.backgroundColor = UIColor.clear
    }

    // ---- BEGIN EXTERNAL API ----

    @objc func prepare(_ command: CDVInvokedUrlCommand){
        let status = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
        if (status == AVAuthorizationStatus.notDetermined) {
            // Request permission before preparing scanner
            AVCaptureDevice.requestAccess(for: AVMediaType.video, completionHandler: { (granted) -> Void in
                // attempt to prepScanner only after the request returns
                self.backgroundThread(delay: 0, completion: {
                    if(self.prepScanner(command: command)){
                        self.getStatus(command)
                    }
                })
            })
        } else {
            if(self.prepScanner(command: command)){
                self.getStatus(command)
            }
        }
    }

    @objc func scan(_ command: CDVInvokedUrlCommand){
        if(self.prepScanner(command: command)){
            nextScanningCommand = command
            scanning = true
        }
    }

    @objc func cancelScan(_ command: CDVInvokedUrlCommand){
        if(self.prepScanner(command: command)){
            scanning = false
            if(nextScanningCommand != nil){
                self.sendErrorCode(command: nextScanningCommand!, error: QRScannerError.scan_canceled)
            }
            self.getStatus(command)
        }
    }

    private func setQRUI() {
        iciciDesignView = UIView(frame: CGRect(x: 0, y: 0, width: 350, height: 650))
        iciciDesignView.backgroundColor = .clear
        iciciDesignView.tag = 1102
        iciciDesignView.translatesAutoresizingMaskIntoConstraints = false
        self.webView?.addSubview(iciciDesignView)
        
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 350, height: 55))
        header.backgroundColor = .white
        header.translatesAutoresizingMaskIntoConstraints = false
        iciciDesignView.addSubview(header)
        
        let headerTitle = UILabel(frame: CGRect(x: 90, y: 10, width: 30, height: 30))
        headerTitle.text = "Digital Token"
        headerTitle.textColor = .black
        headerTitle.textAlignment = .left
        headerTitle.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        
        let back = UIButton()
        back.backgroundColor = UIColor(red: 255/255, green: 251/255, blue: 248/255, alpha: 1)
        if #available(iOS 13.0, *) {
            back.setImage(UIImage(systemName: "chevron.left"), for: .normal)
            back.tintColor = UIColor(red: 251/255, green: 121/255, blue: 25/255, alpha: 1)
            back.layer.cornerRadius = 10
            back.layer.borderWidth = 0.5
            back.layer.borderColor = UIColor(red: 251/255, green: 121/255, blue: 25/255, alpha: 1).cgColor
        } else {
            // Fallback on earlier versions
        }
        back.addTarget(self, action: #selector(back_click), for: .touchUpInside)
        back.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(back)
        
        let body = UIView(frame: CGRect(x: 0, y: 60, width: 350, height: 550))
        body.backgroundColor = .clear
        body.translatesAutoresizingMaskIntoConstraints = false
        iciciDesignView.addSubview(body)
        
        let view1 = UIView()
        view1.backgroundColor = .red
        let view2 = UIView()
        view2.backgroundColor = .green
        let view3 = UIView()
        view3.backgroundColor = .blue
        let view4 = UIView()
        view4.backgroundColor = .purple
        
        let viewScan = UIView()
        viewScan.translatesAutoresizingMaskIntoConstraints = false
        viewScan.backgroundColor = .clear
        body.addSubview(viewScan)
        let viewScanHeight = self.webView.frame.width / 2
        
        for view in [view1, view2, view3, view4] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            body.addSubview(view)
        }
        
        
        let imageCorner = UIImageView()
        imageCorner.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(imageCorner)
        let assetURL = Bundle.main.bundleURL.appendingPathComponent("www/qr_border.png")
        if let data = NSData(contentsOf: assetURL),
           let image = UIImage(data: data as Data){
            imageCorner.image = image
        }
        
        let title = UILabel()
        title.text = "Scan your QR Code"
        title.textColor = .white
        title.textAlignment = .center
        title.font = UIFont.preferredFont(forTextStyle: .title1)
        title.translatesAutoresizingMaskIntoConstraints = false
        view1.addSubview(title)
        
        let disciption = UILabel()
        disciption.text = "The QR Code will be detected automatically once you have positioned the code within the guide lines"
        disciption.textColor = .white
        disciption.textAlignment = .center
        disciption.numberOfLines = 0
        disciption.font = UIFont.preferredFont(forTextStyle: .callout)
        disciption.translatesAutoresizingMaskIntoConstraints = false
        view4.addSubview(disciption)
        
        NSLayoutConstraint.activate([
            iciciDesignView.topAnchor.constraint(equalTo: self.webView.topAnchor, constant: 0),
            iciciDesignView.leadingAnchor.constraint(equalTo: self.webView.leadingAnchor, constant: 0),
            iciciDesignView.trailingAnchor.constraint(equalTo: self.webView.trailingAnchor, constant: 0),
            iciciDesignView.bottomAnchor.constraint(equalTo: self.webView.bottomAnchor, constant: 0),
            
            header.topAnchor.constraint(equalTo: iciciDesignView.topAnchor, constant: 0),
            header.leadingAnchor.constraint(equalTo: iciciDesignView.leadingAnchor, constant: 0),
            header.trailingAnchor.constraint(equalTo: iciciDesignView.trailingAnchor, constant: 0),
            
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 0),
            body.leadingAnchor.constraint(equalTo: iciciDesignView.leadingAnchor, constant: 0),
            body.trailingAnchor.constraint(equalTo: iciciDesignView.trailingAnchor, constant: 0),
            body.bottomAnchor.constraint(equalTo: iciciDesignView.bottomAnchor, constant: 0),
        ])
        
        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: iciciDesignView.safeAreaLayoutGuide.topAnchor, constant: 10),
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 25),
            back.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -20),
            back.heightAnchor.constraint(equalToConstant: 35),
            back.widthAnchor.constraint(equalTo: back.heightAnchor,constant: 0),
            
            headerTitle.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 15),
            headerTitle.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -15),
            headerTitle.centerYAnchor.constraint(equalTo: back.centerYAnchor, constant: 0),
            
            ])
        
        
        NSLayoutConstraint.activate([
            view1.topAnchor.constraint(equalTo: body.topAnchor, constant: 0),
            view1.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 0),
            view1.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: 0),
            view1.heightAnchor.constraint(equalToConstant: viewScanHeight - 40),
            
            viewScan.topAnchor.constraint(equalTo: view1.bottomAnchor, constant: 0),
            viewScan.heightAnchor.constraint(equalToConstant: viewScanHeight),
            viewScan.widthAnchor.constraint(equalToConstant: viewScanHeight),
            viewScan.centerXAnchor.constraint(equalTo: body.centerXAnchor, constant: 0),
            
            imageCorner.topAnchor.constraint(equalTo: viewScan.topAnchor, constant: -5),
            imageCorner.leadingAnchor.constraint(equalTo: viewScan.leadingAnchor, constant: -5),
            imageCorner.trailingAnchor.constraint(equalTo: viewScan.trailingAnchor, constant: 5),
            imageCorner.bottomAnchor.constraint(equalTo: viewScan.bottomAnchor, constant: 5),
            
            view2.topAnchor.constraint(equalTo: viewScan.topAnchor, constant: 0),
            view2.leadingAnchor.constraint(equalTo: view1.leadingAnchor, constant: 0),
            view2.trailingAnchor.constraint(equalTo: viewScan.leadingAnchor, constant: 0),
            view2.bottomAnchor.constraint(equalTo: viewScan.bottomAnchor, constant: 0),
//
            view3.topAnchor.constraint(equalTo: viewScan.topAnchor, constant: 0),
            view3.leadingAnchor.constraint(equalTo: viewScan.trailingAnchor, constant: 0),
            view3.trailingAnchor.constraint(equalTo: view1.trailingAnchor, constant: 0),
            view3.bottomAnchor.constraint(equalTo: viewScan.bottomAnchor, constant: 0),
            
            view4.topAnchor.constraint(equalTo: viewScan.bottomAnchor, constant: 0),
            view4.leadingAnchor.constraint(equalTo: view1.leadingAnchor, constant: 0),
            view4.trailingAnchor.constraint(equalTo: view1.trailingAnchor, constant: 0),
            view4.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: 0),
            
            ])
        
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view1.leadingAnchor, constant: 35),
            title.bottomAnchor.constraint(equalTo: view1.bottomAnchor, constant: -35),
            title.centerXAnchor.constraint(equalTo: view1.centerXAnchor, constant: 0),

            disciption.topAnchor.constraint(equalTo: view4.topAnchor, constant: 35),
            disciption.leadingAnchor.constraint(equalTo: view4.leadingAnchor, constant: 35),
            disciption.centerXAnchor.constraint(equalTo: view4.centerXAnchor, constant: 0),
            ])
        DispatchQueue.main.async {
            self.cameraView.frame = body.frame
            self.cameraView.translatesAutoresizingMaskIntoConstraints = false
            
            NSLayoutConstraint.activate([
                self.cameraView.topAnchor.constraint(equalTo: body.topAnchor, constant: 0),
                self.cameraView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 0),
                self.cameraView.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: 0),
                self.cameraView.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: 0),
                ])
        }
        
    }
    @objc private func back_click() {
        self.makeOpaque()
        self.cameraView.removeFromSuperview()
        self.iciciDesignView.removeFromSuperview()
    }

    @objc func show(_ command: CDVInvokedUrlCommand) {
        self.webView?.isOpaque = false
        self.webView?.backgroundColor = UIColor.clear
        self.getStatus(command)
        self.cameraView.frame = self.webView.bounds
        self.webView?.addSubview(self.cameraView)
        self.setQRUI()
    }

    @objc func hide(_ command: CDVInvokedUrlCommand) {
        self.makeOpaque()
        self.getStatus(command)
        self.cameraView.removeFromSuperview()
        self.iciciDesignView.removeFromSuperview()
    }

    @objc func pausePreview(_ command: CDVInvokedUrlCommand) {
        if(scanning){
            paused = true;
            scanning = false;
        }
        captureVideoPreviewLayer?.connection?.isEnabled = false
        self.getStatus(command)
    }

    @objc func resumePreview(_ command: CDVInvokedUrlCommand) {
        if(paused){
            paused = false;
            scanning = true;
        }
        captureVideoPreviewLayer?.connection?.isEnabled = true
        self.getStatus(command)
    }

    // backCamera is 0, frontCamera is 1

    @objc func useCamera(_ command: CDVInvokedUrlCommand){
        let index = command.arguments[0] as! Int
        if(currentCamera != index){
            // camera change only available if both backCamera and frontCamera exist
            if(backCamera != nil && frontCamera != nil){
                // switch camera
                currentCamera = index
                if(self.prepScanner(command: command)){
                    do {
                        captureSession!.beginConfiguration()
                        let currentInput = captureSession?.inputs[0] as! AVCaptureDeviceInput
                        captureSession!.removeInput(currentInput)
                        let input = try self.createCaptureDeviceInput()
                        captureSession!.addInput(input)
                        captureSession!.commitConfiguration()
                        self.getStatus(command)
                    } catch CaptureError.backCameraUnavailable {
                        self.sendErrorCode(command: command, error: QRScannerError.back_camera_unavailable)
                    } catch CaptureError.frontCameraUnavailable {
                        self.sendErrorCode(command: command, error: QRScannerError.front_camera_unavailable)
                    } catch CaptureError.couldNotCaptureInput(let error){
                        print(error.localizedDescription)
                        self.sendErrorCode(command: command, error: QRScannerError.camera_unavailable)
                    } catch {
                        self.sendErrorCode(command: command, error: QRScannerError.unexpected_error)
                    }

                }
            } else {
                if(backCamera == nil){
                    self.sendErrorCode(command: command, error: QRScannerError.back_camera_unavailable)
                } else {
                    self.sendErrorCode(command: command, error: QRScannerError.front_camera_unavailable)
                }
            }
        } else {
            // immediately return status if camera is unchanged
            self.getStatus(command)
        }
    }

    @objc func enableLight(_ command: CDVInvokedUrlCommand) {
        if(self.prepScanner(command: command)){
            self.configureLight(command: command, state: true)
        }
    }

    @objc func disableLight(_ command: CDVInvokedUrlCommand) {
        if(self.prepScanner(command: command)){
            self.configureLight(command: command, state: false)
        }
    }

    @objc func destroy(_ command: CDVInvokedUrlCommand) {
        self.makeOpaque()
        if(self.captureSession != nil){
            backgroundThread(delay: 0, background: {
                self.captureSession!.stopRunning()
                self.cameraView.removePreviewLayer()
                self.captureVideoPreviewLayer = nil
                self.metaOutput = nil
                self.captureSession = nil
                self.currentCamera = 0
                self.frontCamera = nil
                self.backCamera = nil
            }, completion: {
                self.getStatus(command)
            })
        } else {
            self.getStatus(command)
        }
    }

    @objc func getStatus(_ command: CDVInvokedUrlCommand){

        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: AVMediaType.video);

        var authorized = false
        if(authorizationStatus == AVAuthorizationStatus.authorized){
            authorized = true
        }

        var denied = false
        if(authorizationStatus == AVAuthorizationStatus.denied){
            denied = true
        }

        var restricted = false
        if(authorizationStatus == AVAuthorizationStatus.restricted){
            restricted = true
        }

        var prepared = false
        if(captureSession?.isRunning == true){
            prepared = true
        }

        var previewing = false
        if(captureVideoPreviewLayer != nil){
            previewing = captureVideoPreviewLayer!.connection!.isEnabled
        }

        var showing = false
        if(self.webView!.backgroundColor == UIColor.clear){
            showing = true
        }

        var lightEnabled = false
        if(backCamera?.torchMode == AVCaptureDevice.TorchMode.on){
            lightEnabled = true
        }

        var canOpenSettings = false
        if #available(iOS 8.0, *) {
            canOpenSettings = true
        }

        var canEnableLight = false
        if(backCamera?.hasTorch == true && backCamera?.isTorchAvailable == true && backCamera?.isTorchModeSupported(AVCaptureDevice.TorchMode.on) == true){
            canEnableLight = true
        }

        var canChangeCamera = false;
        if(backCamera != nil && frontCamera != nil){
            canChangeCamera = true
        }

        let status = [
            "authorized": boolToNumberString(bool: authorized),
            "denied": boolToNumberString(bool: denied),
            "restricted": boolToNumberString(bool: restricted),
            "prepared": boolToNumberString(bool: prepared),
            "scanning": boolToNumberString(bool: scanning),
            "previewing": boolToNumberString(bool: previewing),
            "showing": boolToNumberString(bool: showing),
            "lightEnabled": boolToNumberString(bool: lightEnabled),
            "canOpenSettings": boolToNumberString(bool: canOpenSettings),
            "canEnableLight": boolToNumberString(bool: canEnableLight),
            "canChangeCamera": boolToNumberString(bool: canChangeCamera),
            "currentCamera": String(currentCamera)
        ]

        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }

    @objc func openSettings(_ command: CDVInvokedUrlCommand) {
        if #available(iOS 10.0, *) {
            guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        if UIApplication.shared.canOpenURL(settingsUrl) {
            UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                self.getStatus(command)
            })
        } else {
            self.sendErrorCode(command: command, error: QRScannerError.open_settings_unavailable)
            }
        } else {
            // pre iOS 10.0
            if #available(iOS 8.0, *) {
                UIApplication.shared.openURL(NSURL(string: UIApplication.openSettingsURLString)! as URL)
                self.getStatus(command)
            } else {
                self.sendErrorCode(command: command, error: QRScannerError.open_settings_unavailable)
            }
        }
    }
}
