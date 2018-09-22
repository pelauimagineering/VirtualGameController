//
//  VgcController.swift
//
//
//  Created by Rob Reuss on 9/30/15.
//
//

import Foundation

#if os(iOS) || os(OSX) || os(tvOS)
    import GameController
    import CoreBluetooth
#endif

#if !os(watchOS)

public let VgcControllerDidConnectNotification:     String = "VgcControllerDidConnectNotification"
public let VgcControllerDidDisconnectNotification:  String = "VgcControllerDidDisconnectNotification"

// MARK: - VgcController

/// VgcController is a wrapper around GCController.  Each instance
/// represents a hardware or software controller.  Hardware controllers
/// use GCController, and are wrapped by VgcController, but handlers and
/// properties are simply passed through to provide optimal performance.

/// The VgcController class provides muchly the same interface as
/// GCController, but does not descend from it.  In the case of
/// a hardware controller connected to the system, VgcController
/// encapsulates the controller in the var hardwareController, and
/// maps it's properties to it's own.  This provides a single interface
/// to both custom/software controllers and hardware controllers.

open class VgcController: NSObject, StreamDelegate, VgcStreamerDelegate, NetServiceDelegate  {

    weak open var peripheral: Peripheral!
    var streamer: [StreamDataType: VgcStreamer] = [:]
    
    // Each controller gets it's own copy of a set of elements appropriate to
    // it's profile, and these are used as a backing store for all element/control
    // values.
    @objc open var elements: Elements!
    var centralPublisher: VgcCentralPublisher!
    var hardwareController: GCController!
    @objc var vgcExtendedGamepad: VgcExtendedGamepad!
    @objc var vgcGamepad: VgcGamepad!
    #if os(tvOS)
    @objc var vgcMicroGamepad: VgcMicroGamepad!
    #endif
    
    // Flag to prevent performing two disconnects at the same time
    var disconnecting: Bool = false
    
    // This acts as a reference to one of the three profiles, for convienance
    fileprivate var profile: AnyObject!
    fileprivate var vgcPlayerIndex: GCControllerPlayerIndex
    fileprivate var vgcHandlerQueue: DispatchQueue?
    fileprivate var vgcControllerPausedHandler: ((VgcController) -> Void)?
    fileprivate var vgcMotion: VgcMotion!
    
    open var isHardwareController: Bool { get { return self.hardwareController != nil } }
    open var isLocalController: Bool = false
    
    // Each controller gets it's own set of streams
    var fromCentralInputStream: [StreamDataType: InputStream] = [:]
    var toCentralOutputStream: [StreamDataType: OutputStream] = [:]
    var fromPeripheraInputlStream: [StreamDataType: InputStream] = [:] // These two are only required for a bridged controller
    var toPeripheralOutputStream: [StreamDataType: OutputStream] = [:]
    
    public override init() {
        
        vgcLogDebug("Initializing new Controller")
        
        vgcPlayerIndex = .indexUnset
        
        // Each controller gets their own instance of standard elements that
        // act as a virtual set of hardware elements that profiles map to
        
        if VgcManager.enableLocalController {
            elements = VgcManager.elements
        } else {
            elements = Elements()
        }
        
        super.init()
        
        vgcMotion = VgcMotion(vgcController: self)
        //vgcCustom = VgcCustom(vgcController: self)
        
        #if os(tvOS)
            //vgcMicroGamepad = VgcMicroGamepad(vgcGameController: self)
        #endif
        
        //vgcGamepad = VgcGamepad(vgcGameController: self)
        //vgcExtendedGamepad = VgcExtendedGamepad(vgcGameController: self)
    }
    
    deinit {
        vgcLogDebug("Controller deinitalized")
        NotificationCenter.default.removeObserver(self, forKeyPath: NSNotification.Name.GCControllerDidConnect.rawValue)
        NotificationCenter.default.removeObserver(self, forKeyPath: NSNotification.Name.GCControllerDidDisconnect.rawValue)
    }
    
    // MARK: - Class Properties and Functions
    
    // The Central publisher announces the central service and makes connections
    // with Peripherals before they receive their own Controller instance
    static var centralPublisher: VgcCentralPublisher!
    
    // Internal array that provides backing to "controllers", which is the class property
    // provided by GCController
    internal static var vgcControllers: [VgcController] = []
    
    // A Central can have it's own iCade controller, but only one, because it requires that
    // a text field be exposed on the UI to receive the keyboard input an iCade controller
    // generates.
    open static var iCadeController: VgcController!
    
    // Provide access to the single controller used when in .EnhancementBridge mode, so that
    // the "peripheral" component can send values through this controller to the Central.
    static var enhancedController: VgcController! {
        if vgcControllers.count == 0 { return nil } else { return vgcControllers[0] }
    }
    
    // Hardware controllers have a unique device hash, but it's hidden in the
    // object description string.  This function extracts it.
    class func deviceHashFromController(_ controller: GCController) -> String {
        let components: Array = controller.description.components(separatedBy: " ")
        let deviceHashComponent: String = components.last!
        let keyValueArray: Array = deviceHashComponent.components(separatedBy: "=")
        var deviceHash = keyValueArray.last!
        let trimSet = CharacterSet(charactersIn: ">")
        deviceHash = deviceHash.trimmingCharacters(in: trimSet)
        return deviceHash
    }
    
    // Called as a part of app initailization sequence
    class func setup() {
        
        // Kick off publishing the availability of our service
        // if we have a Central function (note, a Bridge has both
        // a Central and Peripheral role)
        
        if VgcManager.appRole == .Central || deviceIsTypeOfBridge() {
            centralPublisher = VgcCentralPublisher()
            centralPublisher.publishService()
        }
        
        // Capture hardware connections, hiding them from the
        // Central.  Instead, we will issue our own version of
        // the didConnect notification when the deviceInfo property
        // is "set", and the developer is responsible for implementing
        // our version instead of the GCController version:
        // "VgcControllerDidConnectNotification"
        NotificationCenter.default.addObserver(self, selector: #selector(VgcController.controllerDidConnect(_:)), name: NSNotification.Name.GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(VgcController.controllerDidDisconnect(_:)), name: NSNotification.Name.GCControllerDidDisconnect, object: nil)
    }
    
    ///
    /// On the Central (or Bridge) side only a single iCade controller at one time
    /// is allowed because of the way iCade controllers represent themselves as keyboards
    /// and the need to direct input to a text entry field.  A text entry field (hidden) 
    /// must be added to your game to support Central-side iCade controller functionality.
    /// Peripheral-side iCade controllers are also supported and allow for multiple controllers, 
    /// but require the use of an iOS device (in Peripheral mode)
    ///
    open class func enableIcadeController() {
        
        iCadeController = VgcController()
        iCadeController.deviceInfo = DeviceInfo(deviceUID: UUID().uuidString, vendorName: "Generic iCade", attachedToDevice: false, profileType: .ExtendedGamepad, controllerType: .Software, supportsMotion: false)
        
    }
    
    // An array of currently connected controllers, that mimics the same
    // class function on GCCController, combining both software/virtual controllers
    // with hardware controllers
    @objc open class func controllers() -> [VgcController] {
        return vgcControllers
    }
    
    
    // Acts as a pass-through to the same-named method on GCController, for pairing of
    // hardware controllers over bluetooth.
    open class func startWirelessControllerDiscoveryWithCompletionHandler(_ _completionHandler: (() -> Void)?) {
        
        vgcLogDebug("Starting discovery process for MFi hardware controllers")
        GCController.startWirelessControllerDiscovery(completionHandler: _completionHandler)
        
    }
    
    // This is also just a pass-through to GCController to stop discovery
    // of hardware devices
    open class func stopWirelessControllerDiscovery() {
        
        vgcLogDebug("Stopping wireless controller discovery")
        GCController.stopWirelessControllerDiscovery()
        
    }
    
    // MARK: - Network Service

    func openstreams(_ streamDataType: StreamDataType, inputStream: InputStream, outputStream: OutputStream, streamStreamer: VgcStreamer) {
       
        streamer[streamDataType] = streamStreamer
        
        fromPeripheraInputlStream[streamDataType] = inputStream
        toPeripheralOutputStream[streamDataType] = outputStream

        vgcLogDebug("Opening Peripheral-bound streams for stream data type: \(streamDataType)")

        // Open our Peripheral-bound streams
        toPeripheralOutputStream[streamDataType]!.delegate = streamer[streamDataType]
        toPeripheralOutputStream[streamDataType]!.schedule(in: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
        toPeripheralOutputStream[streamDataType]!.open()
        
        fromPeripheraInputlStream[streamDataType]!.delegate = streamer[streamDataType] 
        fromPeripheraInputlStream[streamDataType]!.schedule(in: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
        fromPeripheraInputlStream[streamDataType]!.open()
    }

    

    func receivedNetServiceMessage(_ elementIdentifier: Int, elementValue: Data) {
       
        let element = elements.elementFromIdentifier(elementIdentifier)
        
        // If deviceInfo isn't set yet, we're not ready to handle incoming data
        if self.deviceInfo == nil && element?.type != .deviceInfoElement {
            vgcLogDebug("Received data before device is configured")
            return
        }
        
        // Element is non-nil on success
        if (element != nil) {

            element?.valueAsNSData = elementValue
            
            vgcLogVerbose("Received Data for \(element!.name ): \(elementValue.count) bytes, value: \(element?.value ?? "Unknown/Error" as AnyObject)")
            
            // Don't update the controller if we're in bridgeRelayOnly mode
            if (!deviceIsTypeOfBridge() || !VgcManager.bridgeRelayOnly) { updateGameControllerWithValue(element!) }
            
            // If we're a bridge, send along the value to the Central
            if deviceIsTypeOfBridge() && element?.type != .playerIndex && peripheral != nil && peripheral.haveConnectionToCentral == true {
                
                element?.valueAsNSData = elementValue
                peripheral.browser.sendElementStateOverNetService(element)
                
            }

            
        } else {
            vgcLogError("Got nil element: \(elementIdentifier)")
        }
        
        
    }
    
    open static func sendElementStateToAllPeripherals(_ element: Element) {
        
        // Test if element is generic from VGCManager
        let genericElement = VgcManager.elements.elementFromIdentifier(element.identifier)
        
        for controller in VgcController.controllers() {
            if controller.hardwareController == nil {
  
                // If element is generic, convert it to controller-specific
                if element == genericElement {
                    let controllerSpecificElement = controller.elements.elementFromIdentifier(element.identifier)
                    controllerSpecificElement?.value = element.value
                    controllerSpecificElement?.clearValueAfterTransfer = element.clearValueAfterTransfer
                    controller.sendElementStateToPeripheral(controllerSpecificElement!)
                } else {
                    controller.sendElementStateToPeripheral(element)
                }
                
             }
        }
    }
    
    open func sendElementStateToPeripheral(_ element: Element) {
        
        if element.dataType == .Data {
            if streamer[.largeData] != nil {
                streamer[.largeData]!.writeElement(element, toStream:toPeripheralOutputStream[.largeData]!)
            } else {
                vgcLogDebug("nil stream LargeData error caught");
            }
        } else {
            if streamer[.smallData] != nil {
                streamer[.smallData]!.writeElement(element, toStream:toPeripheralOutputStream[.smallData]!)
            } else {
                vgcLogDebug("nil stream SmallData error caught");
            }
        }
        
    }

    
    // Send a message to the Peripheral that we received an invalid message (based on checksum).
    // This gives the Peripheral an opportunity to take some action, for example, slowing the flow
    // of motion data.
    func sendInvalidMessageSystemMessage() {
        
        let element = elements.systemMessage
        element.value = SystemMessages.receivedInvalidMessage.rawValue as AnyObject
        streamer[.smallData]!.writeElement(element, toStream:toPeripheralOutputStream[.smallData]!)

    }
    
    // Send a message to the Peripheral that we received an invalid message (based on checksum).
    // This gives the Peripheral an opportunity to take some action, for example, slowing the flow
    // of motion data.
    func sendConnectionAcknowledgement() {
        let element = elements.systemMessage
        element.value = SystemMessages.connectionAcknowledgement.rawValue as AnyObject
        if let inStream = streamer[.smallData] {
            if let outStream = toPeripheralOutputStream[.smallData] {
                vgcLogDebug("Sending connection acknowledgement to \(deviceInfo.vendorName)")
                inStream.writeElement(element, toStream: outStream)
            }
        }
    }

    open func disconnect() {
        
        vgcLogDebug("Running disconnect function")
        
        if disconnecting {
            vgcLogDebug("Refusing to run disconnect because already running")
            return
        }
        disconnecting = true
        
        // We don't need to worry about NSNetService stuff if we're dealing with
        // a watch
        if deviceInfo != nil && deviceInfo.controllerType != .Watch {
            
            vgcLogDebug("Closing streams for controller \(deviceInfo.vendorName)")
            
            fromPeripheraInputlStream[.largeData]!.close()
            fromPeripheraInputlStream[.largeData]!.remove(from: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
            fromPeripheraInputlStream[.largeData]!.delegate = nil
            fromPeripheraInputlStream[.smallData]!.close()
            fromPeripheraInputlStream[.smallData]!.remove(from: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
            fromPeripheraInputlStream[.smallData]!.delegate = nil
            
            // If we're a Bridge, pass along the disconnect notice to the Central, and
            // put our peripheral identity into a non-connected state
            if deviceIsTypeOfBridge() && peripheral != nil {
                peripheral.browser.disconnectFromCentral()
                peripheral.haveConnectionToCentral = false
                peripheral.controller = nil
                peripheral = nil
            }
            
            toPeripheralOutputStream[.largeData]!.close()
            toPeripheralOutputStream[.largeData]!.remove(from: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
            toPeripheralOutputStream[.largeData]!.delegate = nil
            toPeripheralOutputStream[.smallData]!.close()
            toPeripheralOutputStream[.smallData]!.remove(from: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
            toPeripheralOutputStream[.smallData]!.delegate = nil

            streamer[.largeData] = nil
            streamer[.smallData] = nil
            
        }
        
        if let deviceInfo = self.deviceInfo {
        
            // Make sure we aren't getting any accidental duplicates of the controller
            var index = 0
            for controller in VgcController.vgcControllers {
                if controller.deviceInfo.deviceUID == deviceInfo.deviceUID {
                    vgcLogDebug("Removing controller \(controller.deviceInfo.vendorName) from controllers array")
                    VgcController.vgcControllers.remove(at: index)
                }
                index += 1
            }
            
            vgcLogDebug("After disconnect controller count is \(VgcController.vgcControllers.count)")
            
            // Notify the app there's been a disconnect
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name(rawValue: VgcControllerDidDisconnectNotification), object: self)
            }
            
            centralPublisher = nil
            
        } else {
            
            vgcLogDebug("Attempted to remove controller but it's deviceInfo was nil.  Controller count is \(VgcController.vgcControllers.count)")
            
        }
        disconnecting = false

    }
 
    func mapElement(_ elementToBeMapped: Element) {
        
        if Elements.customMappings == nil { return }

        if let destinationElementIdentifier = Elements.customMappings.mappings[elementToBeMapped.identifier] {
            let destinationElement = elements.elementFromIdentifier(destinationElementIdentifier)
            destinationElement?.value = elementToBeMapped.value
            if let keyPath = (destinationElement?.setterKeypath(self)) {
                setValue(destinationElement?.value, forKeyPath: keyPath)
            } else {
                vgcLogError("Expected keyPath from element but got nil")
            }
        }

    }
    
    // Update the controller by mapping the controller element to the
    // associated controller property and setting the value
    
    func updateGameControllerWithValue(_ element: Element) {
        
        // Value could be either a string or a float or a double
        var value: Float = 0.0
        
        if element.value is NSNumber {
            value = (element.value as! NSNumber).floatValue
        }
        
        switch(element.type) {
            
        case .systemMessage:
            
            if value < 1 {
                vgcLogError("Receive bad system message type (\(value))")
                return
            }
            
            if let messageType = SystemMessages(rawValue: Int(value)) {
                
                vgcLogDebug("Peripheral sent system message: \(messageType.description)")
                
                switch messageType {
                    
                    // A Bridge uses the Disconnect system message to notify it's Central
                // that it's Peripheral has disconnected
                case .disconnect:
                    
                    disconnect()
                    
                case .receivedInvalidMessage:
                    break
                    
                case .connectionAcknowledgement:
                    break
                }
                
            } else {
                vgcLogError("Expected system message type but got nil")
                return
            }
            
        case .deviceInfoElement:
            
            NSKeyedUnarchiver.setClass(DeviceInfo.self, forClassName: "DeviceInfo")
            if let di = (NSKeyedUnarchiver.unarchiveObject(with: element.valueAsNSData as Data) as? DeviceInfo) {
                deviceInfo = di
            } else {
                vgcLogError("Expected DeviceInfo but got nil")
            }
            
        case .playerIndex:
            
            break
            
        case .image:
            
            if let handler = element.valueChangedHandler {
                (self.handlerQueue).async {
                    handler(self, element)
                }
            }

        case .custom:

            elements.custom[element.identifier]?.valueAsNSData = element.valueAsNSData

            // Call the element-level change handler
            
            if let handler = elements.custom[element.identifier]!.valueChangedHandler {
                (handlerQueue).async {
                    handler(self, element)
                }
            }
            
            // Call the profile-level change handler
            if let handler = Elements.customElements.valueChangedHandler {
                (handlerQueue).async {
                    handler(self, element)
                }
            }
            
            mapElement(element)
            
            break
            
        // All of the standard input elements fall through to here
        default:

            if element.dataType == .Float {
                triggerElementHandlers(element, value: element.value)
            } else {
                triggerElementHandlers(element, value: element.value )
            }
        }
    }
    
    open func triggerElementHandlers(_ element: Element, value: AnyObject) {
        
        if elements.elementsForController(self).contains(element) {
            
            //vgcLogDebug("Setting value \(value) on Keypath \(element.setterKeypath(self))")
            
            if element.dataType == .Float {
                setValue(Float(value as! NSNumber), forKeyPath: element.setterKeypath(self))
            } else if element.dataType == .Double {
                setValue(Double(value as! NSNumber), forKeyPath: element.setterKeypath(self))
            }
            

         
            mapElement(element)
            
        } else {
            
            vgcLogError("Attempt to update an unsupported element \(element.name) on controller \(deviceInfo.vendorName) using keypath \(element.setterKeypath).  Check to confirm profiles match.")
            
        }
    }
    
    @objc open func vibrateDevice() {
        let element = VgcManager.elements.elementFromIdentifier(ElementType.vibrateDevice.rawValue)
        element?.value = 1 as AnyObject
        sendElementStateToPeripheral(element!)
        element?.value = 0 as AnyObject
        sendElementStateToPeripheral(element!)
    }

    // MARK: - Hardware Controller Management
    
    // Because tvOS only implements a sub-set of the motion profiles, a work-around
    // required that references to specific motion profile elements be excluded and
    // so a complete facade was imposed in front of the GCController motion profiles
    // (VgcMotion).  This function sets up handler forwarding from motion hardware
    // to the VGC handler.
    func setupHardwareControllerMotionHandlers() {
        
        // This handler will trigger the VGC level motion handler
        hardwareController.motion?.valueChangedHandler = { (input: GCMotion) in

            self.vgcMotion.callHandler()

        }
        
    }
    
    func setupHardwareControllerForwardingHandlers() {
        
        // We only need these change handlers if we're deal with a
        // hardware controller.  For software controllers, the mapping is handled when
        // dealing with NSNetService stream data.
        
        if deviceInfo.controllerType != .MFiHardware { return }
        
        vgcLogDebug("Setting up hardware controller forwarding")
        
        // Define our change handlers as variables so we can assign them differentially below
        // based on the use of gamepad versus extended gamepad
        let dpadValueChangedHandler = { (input: GCControllerDirectionPad!, x: Float, y: Float) in
            self.elements.dpadXAxis.value = x as AnyObject
            self.elements.dpadYAxis.value = y as AnyObject
            self.peripheral.sendElementState(self.elements.dpadXAxis)
            self.peripheral.sendElementState(self.elements.dpadYAxis)
        }
        
        let leftThumbstickChangedHandler = { (input: GCControllerDirectionPad!, x: Float, y: Float) in
            self.elements.leftThumbstickXAxis.value = x as AnyObject
            self.elements.leftThumbstickYAxis.value = y as AnyObject
            self.peripheral.sendElementState(self.elements.leftThumbstickXAxis)
            self.peripheral.sendElementState(self.elements.leftThumbstickYAxis)
        }
        
        let rightThumbstickChangedHandler = { (input: GCControllerDirectionPad!, x: Float, y: Float) in
            self.elements.rightThumbstickXAxis.value = x as AnyObject
            self.elements.rightThumbstickYAxis.value = y as AnyObject
            self.peripheral.sendElementState(self.elements.rightThumbstickXAxis)
            self.peripheral.sendElementState(self.elements.rightThumbstickYAxis)
        }
        
        let buttonAChangedHandler = { (input: GCControllerButtonInput!, value: Float, pressed: Bool) in
            self.elements.buttonA.value = value as AnyObject
            self.peripheral.sendElementState(self.elements.buttonA)
        }
        
        let buttonBChangedHandler = { (input: GCControllerButtonInput!, value: Float, pressed: Bool) in
            self.elements.buttonB.value = value as AnyObject
            self.peripheral.sendElementState(self.elements.buttonB)
        }
        
        let buttonXChangedHandler = { (input: GCControllerButtonInput!, value: Float, pressed: Bool) in
            self.elements.buttonX.value = value as AnyObject
            self.peripheral.sendElementState(self.elements.buttonX)
        }
        
        let buttonYChangedHandler = { (input: GCControllerButtonInput!, value: Float, pressed: Bool) in
            self.elements.buttonY.value = value as AnyObject
            self.peripheral.sendElementState(self.elements.buttonY)
        }
        
        let leftShoulderChangedHandler = { (input: GCControllerButtonInput!, value: Float, pressed: Bool) in
            self.elements.leftShoulder.value = value as AnyObject
            self.peripheral.sendElementState(self.elements.leftShoulder)
        }
        
        let rightShoulderChangedHandler = { (input: GCControllerButtonInput!, value: Float, pressed: Bool) in
            self.elements.rightShoulder.value = value as AnyObject
            self.peripheral.sendElementState(self.elements.rightShoulder)
        }
        
        let leftTriggerChangedHandler = { (input: GCControllerButtonInput!, value: Float, pressed: Bool) in
            self.elements.leftTrigger.value = value as AnyObject
            self.peripheral.sendElementState(self.elements.leftTrigger)
        }
        
        let rightTriggerChangedHandler = { (input: GCControllerButtonInput!, value: Float, pressed: Bool) in
            self.elements.rightTrigger.value = value as AnyObject
            self.peripheral.sendElementState(self.elements.rightTrigger)
        }
        
        #if os(tvOS)
            if profileType == .MicroGamepad {
                
                microGamepad!.dpad.valueChangedHandler = dpadValueChangedHandler
                microGamepad!.buttonA.valueChangedHandler = buttonAChangedHandler
                microGamepad!.buttonX.valueChangedHandler = buttonXChangedHandler
                
            }
        #endif
        
        if profileType == .Gamepad || profileType == .ExtendedGamepad {
            
            gamepad!.dpad.valueChangedHandler           = dpadValueChangedHandler
            gamepad!.buttonA.valueChangedHandler        = buttonAChangedHandler
            gamepad!.buttonB.valueChangedHandler        = buttonBChangedHandler
            gamepad!.buttonX.valueChangedHandler        = buttonXChangedHandler
            gamepad!.buttonY.valueChangedHandler        = buttonYChangedHandler
            gamepad!.leftShoulder.valueChangedHandler   = leftShoulderChangedHandler
            gamepad!.rightShoulder.valueChangedHandler  = rightShoulderChangedHandler
            
        }
        
        if profileType == .ExtendedGamepad {
            
            extendedGamepad!.dpad.valueChangedHandler               = dpadValueChangedHandler
            extendedGamepad!.leftThumbstick.valueChangedHandler     = leftThumbstickChangedHandler
            extendedGamepad!.rightThumbstick.valueChangedHandler    = rightThumbstickChangedHandler
            extendedGamepad!.buttonA.valueChangedHandler            = buttonAChangedHandler
            extendedGamepad!.buttonB.valueChangedHandler            = buttonBChangedHandler
            extendedGamepad!.buttonX.valueChangedHandler            = buttonXChangedHandler
            extendedGamepad!.buttonY.valueChangedHandler            = buttonYChangedHandler
            extendedGamepad!.leftShoulder.valueChangedHandler       = leftShoulderChangedHandler
            extendedGamepad!.rightShoulder.valueChangedHandler      = rightShoulderChangedHandler
            extendedGamepad!.leftTrigger.valueChangedHandler        = leftTriggerChangedHandler
            extendedGamepad!.rightTrigger.valueChangedHandler       = rightTriggerChangedHandler
            
        }
        
        // The Central (app) is responsible for managing the state of the pause button.
        // When forwarding, we send a long a "blip", flipping the state from on to off,
        // to indicate a button push.
        controllerPausedHandler = { (controller: VgcController) in
            
            self.elements.pauseButton.value = 1.0 as AnyObject
            self.peripheral.sendElementState(self.elements.pauseButton)
            self.elements.pauseButton.value = 0.0 as AnyObject
            self.peripheral.sendElementState(self.elements.pauseButton)
            
        }
        
        // Refresh on all motion changes.  Must go straight to hardware controller because 
        // element-level value changed handlers are unavailable.  The dev may set the value for
        // the handler and it would over-write this.
        hardwareController.motion?.valueChangedHandler = { (input: GCMotion) in
            
            self.elements.motionUserAccelerationX.value = input.userAcceleration.x as AnyObject
            self.peripheral.sendElementState(self.elements.motionUserAccelerationX)
            self.elements.motionUserAccelerationY.value = input.userAcceleration.y as AnyObject
            self.peripheral.sendElementState(self.elements.motionUserAccelerationY)
            self.elements.motionUserAccelerationZ.value = input.userAcceleration.z as AnyObject
            self.peripheral.sendElementState(self.elements.motionUserAccelerationZ)
            
            self.elements.motionGravityX.value = input.gravity.x as AnyObject
            self.peripheral.sendElementState(self.elements.motionGravityX)
            self.elements.motionGravityY.value = input.gravity.y as AnyObject
            self.peripheral.sendElementState(self.elements.motionGravityY)
            self.elements.motionGravityZ.value = input.gravity.z as AnyObject
            self.peripheral.sendElementState(self.elements.motionGravityZ)
            
            #if !os(tvOS)
            self.elements.motionRotationRateX.value = input.rotationRate.x as AnyObject
            self.peripheral.sendElementState(self.elements.motionRotationRateX)
            self.elements.motionRotationRateY.value = input.rotationRate.y as AnyObject
            self.peripheral.sendElementState(self.elements.motionRotationRateY)
            self.elements.motionRotationRateZ.value = input.rotationRate.z as AnyObject
            self.peripheral.sendElementState(self.elements.motionRotationRateX)
            
            self.elements.motionAttitudeX.value = input.attitude.x as AnyObject
            self.peripheral.sendElementState(self.elements.motionAttitudeX)
            self.elements.motionAttitudeY.value = input.attitude.y as AnyObject
            self.peripheral.sendElementState(self.elements.motionAttitudeY)
            self.elements.motionAttitudeZ.value = input.attitude.z as AnyObject
            self.peripheral.sendElementState(self.elements.motionAttitudeZ)
            self.elements.motionAttitudeW.value = input.attitude.w as AnyObject
            self.peripheral.sendElementState(self.elements.motionAttitudeW)
            #endif
        }
        
    }
    
    // We catch these "real" GCController notifications within VgcController,
    // and then pass them along using our custom notification name ("vgcControllerDidConnect").  This allows
    // us to "capture" a hardware controller being connected, and create a
    // VgcController facade object around it.
    @objc public class func controllerDidConnect(_ notification: Notification) {
        
        if notification.object is GCController {
            
            let controller = VgcController()
            
            controller.hardwareController = notification.object as! GCController
            
            // Ignore hardware controller connections to iOS device if it is
            // configured to be in the .Peripheral role.
            if (VgcManager.appRole == .Peripheral || VgcManager.appRole == .MultiplayerPeer) {
                vgcLogDebug("Ignoring hardware device \(String(describing: controller.hardwareController.vendorName)) because we are configured as a Peripheral")
                return
            }
            
            if controller.hardwareController.vendorName == "Generic Controller" {
                vgcLogDebug("Refusing to add hardware controller because is seems to be the unwanted simulator-based controller (vendor name Generic Controller)")
                return
            }
            
            let deviceHash = deviceHashFromController(controller.hardwareController)
            
            for existingController in VgcController.controllers() {
                
                // If we're in .EnhancementBridge mode, we do not allow more than one hardware
                // controller to connect.
                if existingController.deviceInfo.controllerType == .MFiHardware && VgcManager.appRole == .EnhancementBridge { return }
                
                if existingController.deviceInfo != nil {
                    if existingController.deviceInfo.deviceUID == deviceHash {
                        vgcLogDebug("Refusing to add hardware controller because it is already in controllers array \(deviceHash)")
                        return
                    }
                }
            }
            
            vgcLogDebug("Adding hardware controller \(controller.hardwareController.vendorName!)")
            
            var profileType: ProfileType
            
            // Unless we're on tvOS, we're not interested in the microGamepad
            #if !(os(tvOS))
                if controller.hardwareController.extendedGamepad != nil {
                    profileType = .ExtendedGamepad
                } else if (controller.hardwareController.gamepad != nil) {
                    profileType = .Gamepad
                } else {
                    profileType = .Unknown
                }
            #endif
            
            #if os(tvOS)
                if controller.hardwareController.extendedGamepad != nil {
                    profileType = .ExtendedGamepad
                    controller.profile = controller.extendedGamepad
                } else if controller.hardwareController.gamepad != nil {
                    profileType = .Gamepad
                    controller.profile = controller.gamepad
                } else if (controller.hardwareController.microGamepad != nil) {
                    profileType = .MicroGamepad
                    controller.profile = controller.microGamepad
                } else {
                    profileType = .Unknown
                }
            #endif
            
            vgcLogDebug("Profile type set to: \(profileType.description)")
            
            // Assume devices do not support motion.  When configuring deviceInfo for a custom software
            // peripheral, you can indicate motion support (which would be true for all iOS devices)
            var supportsMotion: Bool = false
            
            // If a hardware controller's motion profile is non-nil, it is said to support motion.
            // I think currently the only controller to support motion is the Apple TV Remote.
            if controller.hardwareController.motion != nil { supportsMotion = true }
            
            // If we're in "EnhancementBridge" appRole mode, we are an iOS device directly attached or paired to a hardware controller
            // and want to provide enhancements in the form of virtual controls or motion capability
            //if VgcManager.appRole == .EnhancementBridge { supportsMotion = true }
            
            // Append the hardware controller to our custom list of controllers
            //VgcController.vgcControllers.append(controller)
            
            // Setting the deviceInfo property here will trigger the "VgcControllerDidConnectNotification".
            print("Hardware controller description: \( controller.hardwareController.description), \(String(describing:  controller.hardwareController.vendorName))")
            controller.deviceInfo = DeviceInfo(deviceUID: deviceHash, vendorName: controller.hardwareController.vendorName!, attachedToDevice: controller.hardwareController.isAttachedToDevice, profileType: profileType, controllerType: .MFiHardware, supportsMotion: supportsMotion)
            
        }
    }
    
    // A hardware controller disconnected - we capture this, handle it and
    // send our custom disconnect notification
    @objc public class func controllerDidDisconnect(_ notification: Notification) {
        
        vgcLogDebug("Got hardware didDisconnect notification: \(notification)")
        
        let hardwareController = notification.object as! GCController
        
        let deviceHash = deviceHashFromController(hardwareController)
        
        // Scan for the matching controller in our controllers array, and
        // remove it from said array
        var index: Int = 0
        for controller in VgcController.controllers() {
            vgcLogDebug("Comparing UUID \(controller.deviceInfo.deviceUID) to \(deviceHash)")
            if controller.deviceInfo.deviceUID == deviceHash {
                vgcLogDebug("Removing controller from controllers array: \(hardwareController)")
                VgcController.vgcControllers.remove(at: index)
                NotificationCenter.default.post(name: Notification.Name(rawValue: VgcControllerDidDisconnectNotification), object: controller)
                return
            }
            index += 1
        }
    }

    // Defaults the handler queue to main and exposes the hardware version of the
    // handler queue for hardware devices
    open var handlerQueue:DispatchQueue {
        get {
            if (vgcHandlerQueue == nil) {
                return DispatchQueue.main
            } else {
                return vgcHandlerQueue!
            }
        }
        set {
            vgcHandlerQueue = newValue
        }
    }
    
    // Handler for the pause button.  It is the responsibility of
    // the game side to maintain the state of pause at the app level.
    open var controllerPausedHandler: ((VgcController) -> Void)? {
        didSet {
            // Create a forwarding handler for the pause button
            if deviceInfo.controllerType == .MFiHardware {
                
                hardwareController.controllerPausedHandler = { [unowned self] _ in
                    
                    if let handler = self.vgcControllerPausedHandler {
                        (self.handlerQueue).async {
                            handler(self)
                        }
                    }
                }
                vgcControllerPausedHandler = controllerPausedHandler
            }
        }
    }
    
    @objc open var motion: VgcMotion? {
        return vgcMotion
    }
    
    static func controllerAlreadyExists(_ newController: VgcController) -> (Bool, Int) {
        
        var index = 0
        for existingController in VgcController.controllers() {
            vgcLogDebug("Comparing existing device \(existingController.deviceInfo.vendorName) to new device \(newController.deviceInfo.vendorName)")
            //vgcLogDebug("Comparing existing device ID \(existingController.deviceInfo.deviceUID) to new device ID \(deviceInfo.deviceUID)")
            if existingController.deviceInfo.deviceUID == newController.deviceInfo.deviceUID {
                vgcLogDebug("Found matching existing controller so disconnecting new controller")
                return (true, index)
            }
            index += 1
        }
        return (false, -1)
    }
    
    let lockQueueVgcController = DispatchQueue(label: "net.simplyformed.lockVgcController", attributes: [])
    
    // When deviceInfo arrives from the peripheral and this property is set
    // we send the VgcControllerDidConnectNotification notification because
    // the controller is now properly identified and ready to be used.
    open var deviceInfo: DeviceInfo! {
        
        didSet {
            
            vgcLogDebug("Device info set on controller")
            
            print(deviceInfo)
            
            vgcLogDebug("Confirming controller doesn't already exist among \(VgcController.controllers().count) controllers")
            
            
            if deviceIsTypeOfBridge() {
                if peripheral == nil {
                    vgcLogDebug("Setting up a controller-specific peripheral object for controller \(deviceInfo.vendorName)")
                    peripheral = Peripheral()
                } else {
                    vgcLogDebug("Controller already has a peripheral object \(deviceInfo.vendorName)")
                }
                peripheral.controller = self
                #if os(iOS)
                peripheral.motion.controller = self
                #endif
            }
            
            
            let (existsAlready, index) = VgcController.controllerAlreadyExists(self)
            if existsAlready {
            
                vgcLogDebug("Controller exists already, removing")
                self.lockQueueVgcController.sync {
                    VgcController.vgcControllers.remove(at: index)
                }
            
            }
            
            // Make a game controller out of the Peripheral
            vgcLogDebug("Appending controller \(deviceInfo.vendorName) to vControllers (\(VgcController.controllers().count + 1) controllers with new controller)")
            
            lockQueueVgcController.sync {
                VgcController.vgcControllers.append(self)
            }
            
            switch (deviceInfo.profileType) {
                
            case .MicroGamepad:
                #if os(tvOS)
                    vgcMicroGamepad = VgcMicroGamepad(vgcGameController: self)
                #endif
                break
                
            case .Gamepad:
                vgcGamepad = VgcGamepad(vgcGameController: self)
                
            case .ExtendedGamepad:
                vgcGamepad = VgcGamepad(vgcGameController: self)
                vgcExtendedGamepad = VgcExtendedGamepad(vgcGameController: self)
                
            case.Watch:
                vgcGamepad = VgcGamepad(vgcGameController: self)
                vgcExtendedGamepad = VgcExtendedGamepad(vgcGameController: self)
                
            default:
                vgcLogError("Device profile unknown: \(deviceInfo.profileType.description)")
                
            }
            
            if deviceIsTypeOfBridge()  && deviceInfo.controllerType == .MFiHardware { setupHardwareControllerForwardingHandlers() }
            
            if !deviceIsTypeOfBridge() && deviceInfo.controllerType == .MFiHardware { setupHardwareControllerMotionHandlers() }
            
            if deviceIsTypeOfBridge() { peripheral.bridgePeripheralDeviceInfoToCentral(self) }
            
            if deviceIsTypeOfBridge() { peripheral.browseForServices() }  // Now that we have a peripheral, let the Central know we can act as a peripheral (forwarding)
            
            if !self.isLocalController { sendConnectionAcknowledgement() }
            
            DispatchQueue.main.async {
                
                NotificationCenter.default.post(name: Notification.Name(rawValue: "VgcControllerDidConnectNotification"), object: self)
                
            }
        }
    }
    
    /// Convienance function for profile type
    open var profileType: ProfileType {
        if deviceInfo != nil {
            return deviceInfo.profileType
        } else {
            return .ExtendedGamepad
        }
    }
    
    /// Some controllers directly attach to the game-playing iOS device, such as
    /// a slide-on controller.
    open var attachedToDevice: Bool {
        if deviceInfo != nil {
            return deviceInfo.attachedToDevice
        } else {
            return false
        }
    }
    
    open var vendorName: String {
        return deviceInfo.vendorName
    }
    
    // The Central can send a player index to the controller, which in turn displays
    // to the user.  This is the only case in GCController when data moves from Central
    // to Peripheral, and that's true as well in this implementation.

    open var playerIndex: GCControllerPlayerIndex {
        get {
            return vgcPlayerIndex
        }
        set {
            
            if vgcPlayerIndex == newValue { return }
            
            vgcPlayerIndex = newValue
            
            if deviceInfo.controllerType == .MFiHardware {
                
                if hardwareController != nil { hardwareController.playerIndex = newValue }
                
            } else  {
                
                if centralPublisher != nil && centralPublisher.haveConnectionToPeripheral && toPeripheralOutputStream[.smallData] != nil {
                    
                    vgcLogDebug("Sending player index \(newValue.rawValue) to controller \(deviceInfo.vendorName)")
                    
                    let playerIndexElement = elements.playerIndex
                    playerIndexElement.value = playerIndex.rawValue as AnyObject
                    
                    streamer[.smallData]!.writeElement(playerIndexElement, toStream: toPeripheralOutputStream[.smallData]!)
                    
                    NotificationCenter.default.post(name: Notification.Name(rawValue: VgcNewPlayerIndexNotification), object: self)
                    
                } else {
                    vgcLogDebug("PERIPHERAL: Cannot send player index, no connection, no netservice manager or no open stream")
                }

            }
        }
    }
    
    #if os(tvOS)
    @objc public var microGamepad: VgcMicroGamepad? {

        return vgcMicroGamepad

    }
    #endif
    
    @objc open var extendedGamepad: VgcExtendedGamepad? {

        return vgcExtendedGamepad

    }
    
    @objc open var gamepad: VgcGamepad? {

        return vgcGamepad

    }
    
    // The profile level change handler is called in response to
    // changes in the value of any of it's elements.  This function
    // provides a single method to call the handler irrespective of
    // which profile the controller supports.
    func callProfileLevelChangeHandler(_ element: GCControllerElement) {
        
        if deviceInfo.profileType == .ExtendedGamepad || deviceInfo.profileType == .Watch {
            extendedGamepad?.callValueChangedHandler(element)
        } else if deviceInfo.profileType == .Gamepad {
            gamepad?.callValueChangedHandler(element)
        }
        
        #if os(tvOS)
            if deviceInfo.profileType == .MicroGamepad {
                microGamepad!.callValueChangedHandler(element: element)
            }
        #endif
    }
    
}

// MARK: - MicroGamepad Profile

#if os(tvOS)
public class VgcMicroGamepad: GCMicroGamepad {
    
    public var vgcController: VgcController?
    
    private var vgcReportsAbsoluteDpadValues: Bool!
    private var vgcAllowsRotation: Bool!
    
    private var vgcDpad:            VgcControllerDirectionPad
    private var vgcButtonA:         VgcControllerButtonInput
    private var vgcButtonX:         VgcControllerButtonInput
    
    private var vgcValueChangedHandler: GCMicroGamepadValueChangedHandler? // Used for software controllers
    
    init(vgcGameController: VgcController) {
        
        vgcController = vgcGameController
        vgcDpad          = VgcControllerDirectionPad(vgcGameController: vgcGameController, xElement: vgcController!.elements.dpadXAxis, yElement: vgcController!.elements.dpadYAxis)
        vgcButtonA       = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.buttonA)
        vgcButtonX       = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.buttonX)
        
        super.init()
        
    }
    
    ///
    /// Returns a GCController hardware controller, if one is available.
    /// vgcController must be used to get a reference to the VgcController, which
    /// represents software controllers (as well as being a wrapper around the
    /// hardware controller.
    ///
    override public weak var controller: GCController? {
        if vgcController?.deviceInfo.controllerType == .MFiHardware { return self.vgcController!.hardwareController.microGamepad!.controller } else { return nil }
    }
    
    public override var reportsAbsoluteDpadValues: Bool {
        get {
            
            if vgcController?.deviceInfo.controllerType == .MFiHardware {
                return vgcController!.hardwareController.microGamepad!.reportsAbsoluteDpadValues
            } else {
                return vgcReportsAbsoluteDpadValues
            }
            
        }
        set {
            
            if vgcController?.deviceInfo.controllerType == .MFiHardware {
                vgcController!.hardwareController.microGamepad!.reportsAbsoluteDpadValues = newValue
            } else {
                vgcReportsAbsoluteDpadValues = newValue
            }
            
        }
    }
    
    public override var allowsRotation: Bool {
        get {
            
            if vgcController?.deviceInfo.controllerType == .MFiHardware {
                return vgcController!.hardwareController.microGamepad!.allowsRotation
            } else {
                return vgcAllowsRotation
            }
            
        }
        set {
            
            if vgcController?.deviceInfo.controllerType == .MFiHardware {
                vgcController!.hardwareController.microGamepad!.allowsRotation = newValue
            } else {
                vgcAllowsRotation = newValue
            }
            
        }
    }
    
    public override var dpad: GCControllerDirectionPad { get { if vgcController?.deviceInfo.controllerType == .MFiHardware && (vgcDpad.yAxis.value == 0 && vgcDpad.xAxis.value == 0) { return vgcController!.hardwareController.microGamepad!.dpad } else { return vgcDpad } } }
    
    override public var buttonA: GCControllerButtonInput { get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcButtonA.value == 0 { return vgcController!.hardwareController.microGamepad!.buttonA } else { return vgcButtonA } } }
    public override var buttonX: GCControllerButtonInput { get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcButtonX.value == 0 { return vgcController!.hardwareController.microGamepad!.buttonX } else { return vgcButtonX } } }

    
    public override var valueChangedHandler: GCMicroGamepadValueChangedHandler? {
        get {
            return vgcValueChangedHandler!
        }
        set {
            vgcValueChangedHandler = newValue
            if (vgcController?.hardwareController != nil) {
                
                vgcController?.hardwareController.microGamepad?.valueChangedHandler = { (gamepad: GCMicroGamepad, element: GCControllerElement) in
                
                self.callValueChangedHandler(element: element)
                
                }
            }
        }
    }
    
    func callValueChangedHandler(element: GCControllerElement) {
        if let handler = vgcValueChangedHandler {
            (vgcController?.handlerQueue)!.async() {
                handler(self, element)
            }
        }
    }
    
    // The function of the pause element is simply to trigger the handler - it is
    // up to the developer to make sense of what the pause press means.
    @objc var vgcPauseButton: Float {
        get {
            return self.vgcPauseButton
        }
        set {
            
            if let handler = vgcController?.controllerPausedHandler {
                (vgcController?.handlerQueue)!.async() {
                    handler(self.vgcController!)
                }
            }
        }
    }
    
    // Unfortunately, there didn't seem to be any choice but to
    // rename this function because we need to return our own snapshot
    // class, and so cannot override the GCController version.
    public func vgcSaveSnapshot() -> VgcMicroGamepadSnapshot {
        
        let snapshot = VgcMicroGamepadSnapshot(controller: vgcController!)
        return snapshot
        
    }
    
}
#endif

// MARK: - Gamepad Profile
open class VgcGamepad: GCGamepad {
    
    ///
    /// Reference to the VgcController that owns this profile.
    ///
    open var vgcController: VgcController?
    
    fileprivate var vgcValueChangedHandler: GCGamepadValueChangedHandler?  // Used for software controllers
    
    fileprivate var vgcDpad:            VgcControllerDirectionPad
    fileprivate var vgcLeftShoulder:    VgcControllerButtonInput
    fileprivate var vgcRightShoulder:   VgcControllerButtonInput
    fileprivate var vgcButtonA:         VgcControllerButtonInput
    fileprivate var vgcButtonB:         VgcControllerButtonInput
    fileprivate var vgcButtonX:         VgcControllerButtonInput
    fileprivate var vgcButtonY:         VgcControllerButtonInput
    
    init(vgcGameController: VgcController) {
        
        vgcController = vgcGameController
        
        vgcLeftShoulder  = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.leftShoulder)
        vgcRightShoulder = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.rightShoulder)
        vgcDpad          = VgcControllerDirectionPad(vgcGameController: vgcGameController, xElement: vgcController!.elements.dpadXAxis, yElement: vgcController!.elements.dpadYAxis)
        vgcButtonA       = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.buttonA)
        vgcButtonB       = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.buttonB)
        vgcButtonX       = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.buttonX)
        vgcButtonY       = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.buttonY)
        
        super.init()
        
    }
    
    open override var leftShoulder: GCControllerButtonInput { get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcLeftShoulder.value == 0 { return vgcController!.hardwareController.gamepad!.leftShoulder } else { return vgcLeftShoulder } } }
    open override var rightShoulder: GCControllerButtonInput { get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcRightShoulder.value == 0 { return vgcController!.hardwareController.gamepad!.rightShoulder } else { return vgcRightShoulder } } }
    open override var dpad: GCControllerDirectionPad { get { if vgcController?.deviceInfo.controllerType == .MFiHardware && (vgcDpad.yAxis.value == 0 && vgcDpad.xAxis.value == 0) { return vgcController!.hardwareController.gamepad!.dpad } else { return vgcDpad } } }
    open override var buttonA: GCControllerButtonInput { get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcButtonA.value == 0 { return vgcController!.hardwareController.gamepad!.buttonA } else { return vgcButtonA } } }
    open override var buttonB: GCControllerButtonInput { get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcButtonB.value == 0 { return vgcController!.hardwareController.gamepad!.buttonB } else { return vgcButtonB } } }
    open override var buttonX: GCControllerButtonInput { get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcButtonX.value == 0 { return vgcController!.hardwareController.gamepad!.buttonX } else { return vgcButtonX } } }
    open override var buttonY: GCControllerButtonInput { get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcLeftShoulder.value == 0 { return vgcController!.hardwareController.gamepad!.buttonY } else { return vgcButtonY } } }
    
    ///
    /// Returns a GCController hardware controller, if one is available.
    /// vgcController must be used to get a reference to the VgcController, which
    /// represents software controllers (as well as being a wrapper around the
    /// hardware controller.
    ///
    override open weak var controller: GCController? {
        if vgcController?.deviceInfo.controllerType == .MFiHardware { return vgcController!.hardwareController.gamepad!.controller } else { return nil }
    }
    
    ///
    /// Same behavior as the GCController version.
    ///
    open override var valueChangedHandler: GCGamepadValueChangedHandler? {
        get {
            return vgcValueChangedHandler!
        }
        set {
            
            vgcValueChangedHandler = newValue
            if (vgcController?.hardwareController != nil) { vgcController?.hardwareController.gamepad?.valueChangedHandler = { (gamepad: GCGamepad, element: GCControllerElement) in
                
                self.callValueChangedHandler(element)
                
                }
            }
        }
    }
    
    func callValueChangedHandler(_ element: GCControllerElement) {
        if let handler = vgcValueChangedHandler {
            (vgcController?.handlerQueue)!.async {
                handler(self, element)
            }
        }
    }
    
    // The function of the pause element is simply to trigger the handler - it is
    // up to the developer to make sense of what the pause press means.
    @objc var vgcPauseButton: Float {
        get {
            return self.vgcPauseButton
        }
        set {
            
            if let handler = vgcController?.controllerPausedHandler {
                (vgcController?.handlerQueue)!.async {
                    handler(self.vgcController!)
                }
            }
        }
    }
    
    // Unfortunately, there didn't seem to be any choice but to
    // rename this function because we need to return our own snapshot
    // class, and so cannot override the GCController version.
    open func vgcSaveSnapshot() -> VgcGamepadSnapshot {
        
        let snapshot = VgcGamepadSnapshot(controller: self.vgcController!)
        return snapshot
        
    }
    
}

// MARK: - Extended Gamepad Profile
open class VgcExtendedGamepad: GCExtendedGamepad {
    
    ///
    /// Reference to the VgcController that owns this profile.
    ///
    open var vgcController: VgcController!
    
    fileprivate var vgcValueChangedHandler: GCExtendedGamepadValueChangedHandler?
    
    fileprivate var vgcDpad:            VgcControllerDirectionPad
    fileprivate var vgcLeftShoulder:    VgcControllerButtonInput
    fileprivate var vgcRightShoulder:   VgcControllerButtonInput
    fileprivate var vgcButtonA:         VgcControllerButtonInput
    fileprivate var vgcButtonB:         VgcControllerButtonInput
    fileprivate var vgcButtonX:         VgcControllerButtonInput
    fileprivate var vgcButtonY:         VgcControllerButtonInput
    fileprivate var vgcLeftThumbstick:  VgcControllerDirectionPad
    fileprivate var vgcRightThumbstick: VgcControllerDirectionPad
    fileprivate var vgcLeftTrigger:     VgcControllerButtonInput
    fileprivate var vgcRightTrigger:    VgcControllerButtonInput
    
    init(vgcGameController: VgcController) {
        
        vgcController = vgcGameController
        
        vgcLeftShoulder  = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.leftShoulder)
        vgcRightShoulder = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.rightShoulder)
        vgcDpad          = VgcControllerDirectionPad(vgcGameController: vgcGameController, xElement: vgcController!.elements.dpadXAxis, yElement: vgcController!.elements.dpadYAxis)
        vgcButtonA       = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.buttonA)
        vgcButtonB       = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.buttonB)
        vgcButtonX       = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.buttonX)
        vgcButtonY       = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.buttonY)
        
        // Extended properties
        vgcLeftThumbstick   = VgcControllerDirectionPad(vgcGameController: vgcGameController, xElement: vgcController.elements.leftThumbstickXAxis, yElement: vgcController.elements.leftThumbstickYAxis)
        vgcRightThumbstick  = VgcControllerDirectionPad(vgcGameController: vgcGameController, xElement: vgcController.elements.rightThumbstickXAxis, yElement: vgcController.elements.rightThumbstickYAxis)
        vgcLeftTrigger      = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.leftTrigger)
        vgcRightTrigger     = VgcControllerButtonInput(vgcGameController: vgcGameController, element: vgcController!.elements.rightTrigger)
        
        super.init()
        
    }
    
    // When these get set they will triger the handlers
    required convenience public init(coder decoder: NSCoder) {
        
        let vgcController = decoder.decodeObject(forKey: "vgcController") as! VgcController
        
        self.init(vgcGameController: vgcController)
        
        vgcLeftShoulder.value = decoder.decodeFloat(forKey: "leftShoulder")
        vgcRightShoulder.value = decoder.decodeFloat(forKey: "rightShoulder")
        vgcDpad.xAxis.value = decoder.decodeFloat(forKey: "dpadX")
        vgcDpad.yAxis.value = decoder.decodeFloat(forKey: "dpadY")
        vgcButtonA.value = decoder.decodeFloat(forKey: "buttonA")
        vgcButtonB.value = decoder.decodeFloat(forKey: "buttonB")
        vgcButtonX.value = decoder.decodeFloat(forKey: "buttonX")
        vgcButtonY.value = decoder.decodeFloat(forKey: "buttonY")
        vgcLeftTrigger.value = decoder.decodeFloat(forKey: "leftTrigger")
        vgcRightTrigger.value = decoder.decodeFloat(forKey: "rightTrigger")
        
        vgcRightThumbstick.xAxis.value = decoder.decodeFloat(forKey: "rightThumbstickX")
        vgcRightThumbstick.yAxis.value = decoder.decodeFloat(forKey: "rightThumbstickY")
        vgcLeftThumbstick.xAxis.value = decoder.decodeFloat(forKey: "leftThumbstickX")
        vgcLeftThumbstick.yAxis.value = decoder.decodeFloat(forKey: "leftThumbstickY")
        
    }
    
    // These will use the getters that return both software and hardware values
    func encodeWithCoder(_ coder: NSCoder) {
        
        coder.encode(vgcController, forKey: "vgcController")
        
        coder.encode(leftShoulder.value, forKey: "leftShoulder")
        coder.encode(rightShoulder.value, forKey: "rightShoulder")
        coder.encode(dpad.xAxis.value, forKey: "dpadX")
        coder.encode(dpad.yAxis.value, forKey: "dpadY")
        coder.encode(buttonA.value, forKey: "buttonA")
        coder.encode(buttonB.value, forKey: "buttonB")
        coder.encode(buttonX.value, forKey: "buttonX")
        coder.encode(buttonY.value, forKey: "buttonY")
        coder.encode(leftTrigger.value, forKey: "leftTrigger")
        coder.encode(rightTrigger.value, forKey: "rightTrigger")
        
        coder.encode(leftThumbstick.xAxis.value, forKey: "leftThumbstickX")
        coder.encode(leftThumbstick.yAxis.value, forKey: "leftThumbstickY")
        coder.encode(rightThumbstick.xAxis.value, forKey: "rightThumbstickX")
        coder.encode(rightThumbstick.yAxis.value, forKey: "rightThumbstickY")
        
    }
    
    ///
    /// Returns a GCController hardware controller, if one is available.
    /// vgcController must be used to get a reference to the VgcController, which
    /// represents software controllers (as well as being a wrapper around the
    /// hardware controller.
    ///
    override open weak var controller: GCController? {
        if vgcController?.deviceInfo.controllerType == .MFiHardware { return vgcController!.hardwareController.extendedGamepad!.controller } else { return nil }
    }
    
    // These getters decide if they should return the VGC version of the element value
    // (which software-based peripherals are supported by) or the hardware controller version.
    open override var leftShoulder: GCControllerButtonInput {
        get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcLeftShoulder.value == 0 { return (vgcController?.hardwareController.extendedGamepad!.leftShoulder)! } else { return vgcLeftShoulder } } }
    
    open override var rightShoulder: GCControllerButtonInput {
        get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcRightShoulder.value == 0 { return (vgcController?.hardwareController.extendedGamepad!.rightShoulder)! } else { return vgcRightShoulder } }
    }
    
    open override var dpad: GCControllerDirectionPad {
        get { if vgcController?.deviceInfo.controllerType == .MFiHardware && (vgcDpad.yAxis.value == 0 && vgcDpad.xAxis.value == 0)   { return (vgcController?.hardwareController.extendedGamepad!.dpad)! } else { return vgcDpad } }
    }
    open override var buttonA: GCControllerButtonInput {
        get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcButtonA.value == 0 {
            return (vgcController?.hardwareController.extendedGamepad!.buttonA)!
        } else {
            return vgcButtonA } }
    }
    open override var buttonB: GCControllerButtonInput {
        get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcButtonB.value == 0 { return (vgcController?.hardwareController.extendedGamepad!.buttonB)! } else { return vgcButtonB } }
    }
    open override var buttonX: GCControllerButtonInput {
        get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcButtonX.value == 0 { return (vgcController?.hardwareController.extendedGamepad!.buttonX)! } else { return vgcButtonX } }
    }
    open override var buttonY: GCControllerButtonInput {
        get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcButtonY.value == 0 { return (vgcController?.hardwareController.extendedGamepad!.buttonY)! } else { return vgcButtonY } }
    }
    
    // Extended profile-specific properties
    open override var leftTrigger: GCControllerButtonInput {
        get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcLeftTrigger.value == 0 { return (vgcController?.hardwareController.extendedGamepad!.leftTrigger)! } else { return vgcLeftTrigger } }
    }
    
    open override var rightTrigger: GCControllerButtonInput {
        get { if vgcController?.deviceInfo.controllerType == .MFiHardware && vgcRightTrigger.value == 0 { return (vgcController?.hardwareController.extendedGamepad!.rightTrigger)! } else { return vgcRightTrigger } }
    }
    
    open override var leftThumbstick: GCControllerDirectionPad {
        get { if vgcController?.deviceInfo.controllerType == .MFiHardware && (vgcLeftThumbstick.yAxis.value == 0 && vgcLeftThumbstick.xAxis.value == 0) { return (vgcController?.hardwareController.extendedGamepad!.leftThumbstick)! } else { return vgcLeftThumbstick } }
    }
    
    open override var rightThumbstick: GCControllerDirectionPad {
        get { if vgcController?.deviceInfo.controllerType == .MFiHardware && (vgcRightThumbstick.yAxis.value == 0 && vgcRightThumbstick.xAxis.value == 0) { return (vgcController?.hardwareController.extendedGamepad!.rightThumbstick)! } else { return vgcRightThumbstick } }
    }
    
    // The function of the pause element is simply to trigger the handler - it is
    // up to the developer to make sense of what the pause press means.
    @objc var vgcPauseButton: Float {
        get {
            return self.vgcPauseButton
        }
        set {
            
            if let handler = vgcController?.controllerPausedHandler {
                (vgcController?.handlerQueue)!.async {
                    handler(self.vgcController!)
                }
            }
        }
    }
    
    // This is the profile-level value changed handler, providing a handler
    // call for any element value change on the profile.  Each profile has one
    // of these.
    open override var valueChangedHandler: GCExtendedGamepadValueChangedHandler? {
        get {
            return self.vgcValueChangedHandler!
        }
        set {
            vgcValueChangedHandler = newValue
            //if (vgcController?.hardwareController != nil) { vgcController?.hardwareController.extendedGamepad?.valueChangedHandler = newValue }
            if (vgcController?.hardwareController != nil) { vgcController?.hardwareController.extendedGamepad?.valueChangedHandler = { (gamepad: GCExtendedGamepad, element: GCControllerElement) in
                
                self.callValueChangedHandler(element)
                
                } }
        }
    }
    
    // Call the handler using the developer-specified handler queue,
    // if any.  We default it to main.
    func callValueChangedHandler(_ element: GCControllerElement) {
        //vgcController.mapElements()
        if let handler = vgcValueChangedHandler {
            (vgcController?.handlerQueue)!.async {
                handler(self, element)
            }
        }
    }
    
    
    // Unfortunately, there didn't seem to be any choice but to
    // rename this function because we need to return our own snapshot
    // class, and so cannot override the GCController version.
    open func vgcSaveSnapshot() -> VgcExtendedGamepadSnapshot {
        
        let snapshot = VgcExtendedGamepadSnapshot(controller: self.vgcController!)
        return snapshot
        
    }
}

// MARK: - Motion Profile
open class VgcMotion: NSObject {
    
    fileprivate var vgcController: VgcController?
    
    fileprivate var vgcGravity: GCAcceleration!
    fileprivate var vgcUserAcceleration: GCAcceleration!
    fileprivate var vgcAttitude: GCQuaternion!
    fileprivate var vgcRotationRate: GCRotationRate!
    
    public typealias VgcMotionValueChangedHandler = (VgcMotion) -> Void
    fileprivate var vgcValueChangedHandler: VgcMotionValueChangedHandler?
   
    init(vgcController: VgcController) {
        
        self.vgcController = vgcController
        vgcGravity = GCAcceleration()
        vgcUserAcceleration = GCAcceleration()
        vgcAttitude = GCQuaternion()
        vgcRotationRate = GCRotationRate()
        
        super.init()
        
    }
    
    ///
    /// Returns a GCController hardware controller, if one is available.
    /// vgcController must be used to get a reference to the VgcController, which
    /// represents software controllers (as well as being a wrapper around the
    /// hardware controller.
    ///
    open weak var controller: GCController? {
        if vgcController?.deviceInfo.controllerType == .MFiHardware { return vgcController!.hardwareController.motion!.controller } else { return nil }
    }
    
    
    @objc open var userAcceleration: GCAcceleration {
        get {
            if vgcController?.deviceInfo.controllerType == .MFiHardware { return (vgcController?.hardwareController.motion?.userAcceleration)! } else { return vgcUserAcceleration }
        }
        set {
            vgcUserAcceleration = newValue
        }
    }
    
    @objc var motionUserAccelerationX: Double {
        get {
            if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.userAcceleration.x)!) } else { return Double(vgcUserAcceleration.x) }
        }
        set {
            vgcUserAcceleration.x = Double(newValue)
            callHandler()
        }
    }
    
    @objc var motionUserAccelerationY: Double {
        get {
            if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.userAcceleration.y)!) } else { return Double(vgcUserAcceleration.y) }
        }
        set {
            vgcUserAcceleration.y = Double(newValue)
            callHandler()
        }
    }
    
    @objc var motionUserAccelerationZ: Double {
        get {
            if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.userAcceleration.z)!) } else { return Double(vgcUserAcceleration.z) }
        }
        set {
            vgcUserAcceleration.z = Double(newValue)
            callHandler()
        }
    }
    
    @objc open var attitude: GCQuaternion {
        get {
            #if !os(tvOS)
                if vgcController?.deviceInfo.controllerType == .MFiHardware { return (vgcController?.hardwareController.motion?.attitude)! }
            #endif
            return vgcAttitude
        }
        set {
            vgcAttitude = newValue
        }
    }
    
    @objc var motionAttitudeX: Double {
        get {
            #if !os(tvOS)
                if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.attitude.x)!) }
            #endif
            return Double(vgcAttitude.x)
        }
        set {
            vgcAttitude.x = Double(newValue)
            callHandler()
        }
    }
    
    @objc var motionAttitudeY: Double {
        get {
            #if !os(tvOS)
                if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.attitude.y)!) }
            #endif
            return Double(vgcAttitude.y)
        }
        set {
            vgcAttitude.y = Double(newValue)
            callHandler()
        }
    }
    
    @objc var motionAttitudeZ: Double {
        get {
            #if !os(tvOS)
                if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.attitude.z)!) }
            #endif
            return Double(vgcAttitude.z)
        }
        set {
            vgcAttitude.z = Double(newValue)
            callHandler()
            
        }
    }
    
    @objc var motionAttitudeW: Double {
        get {
            #if !os(tvOS)
                if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.attitude.w)!) }
            #endif
            return Double(vgcAttitude.w)
        }
        set {
            vgcAttitude.w = Double(newValue)
            callHandler()
            
        }
    }
    
    @objc open var rotationRate: GCRotationRate {
        get {
            #if !os(tvOS)
                if vgcController?.deviceInfo.controllerType == .MFiHardware { return (vgcController?.hardwareController.motion?.rotationRate)! }
            #endif
            return vgcRotationRate
        }
        set {
            vgcRotationRate = newValue
        }
    }
    
    @objc var motionRotationRateX: Double {
        get {
            #if !os(tvOS)
                if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.rotationRate.x)!) }
            #endif
            return Double(vgcRotationRate.x)
        }
        set {
            vgcRotationRate.x = Double(newValue)
            callHandler()
        }
    }
    
    @objc var motionRotationRateY: Double {
        get {
            #if !os(tvOS)
                if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.rotationRate.y)!) }
            #endif
            return Double(vgcRotationRate.y)
        }
        set {
            vgcRotationRate.y = Double(newValue)
            callHandler()
        }
    }
    
    @objc var motionRotationRateZ: Double {
        get {
            #if !os(tvOS)
                if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.rotationRate.z)!) }
            #endif
            return Double(vgcRotationRate.z)
        }
        set {
            vgcRotationRate.z = Double(newValue)
            callHandler()
        }
    }
    
    @objc open var gravity: GCAcceleration {
        get {
            if vgcController?.deviceInfo.controllerType == .MFiHardware { return (vgcController?.hardwareController.motion?.gravity)! } else { return vgcGravity }
            
        }
        set {
            vgcGravity = newValue
        }
    }
    
    @objc var motionGravityX: Double {
        get {
            if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.gravity.x)!) } else { return Double(vgcGravity.x) }
        }
        set {
            vgcGravity.x = Double(newValue)
            callHandler()
        }
    }
    
    @objc var motionGravityY: Double {
        get {
            if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.gravity.y)!) } else { return Double(vgcGravity.y) }
        }
        set {
            vgcGravity.y = Double(newValue)
            callHandler()
        }
    }
    
    @objc var motionGravityZ: Double {
        get {
            if vgcController?.deviceInfo.controllerType == .MFiHardware { return Double((vgcController?.hardwareController.motion?.gravity.z)!) } else { return Double(vgcGravity.z) }
        }
        set {
            vgcGravity.z = Double(newValue)
            callHandler()
            
        }
    }
    
    func callHandler() {
        if let handler = vgcValueChangedHandler {
            (vgcController?.handlerQueue)!.async {
                handler(self)
            }
        }
    }
    
    @objc open var valueChangedHandler: VgcMotionValueChangedHandler? {
        get {
            return vgcValueChangedHandler!
        }
        set {
            vgcValueChangedHandler = newValue
        }
    }
}
    
    
// MARK: - Snapshots

// Convienance functions for snapshots to populate elements with values
func makeButton(_ buttonValue: Float, controller: VgcController, element: Element) -> VgcControllerButtonInput {
    
    element.value = buttonValue as AnyObject
    let button = VgcControllerButtonInput(vgcGameController: controller, element: element)
    return button
    
}

func makeDirectionPad(_ xAxis: Float, yAxis: Float, controller: VgcController, xElement: Element, yElement: Element) -> VgcControllerDirectionPad {
    
    xElement.value = xAxis as AnyObject
    yElement.value = yAxis as AnyObject
    let directionPad = VgcControllerDirectionPad(vgcGameController: controller, xElement: xElement, yElement: yElement)
    return directionPad
    
}

// Encode and decode snapshot NSData

enum EncodingStructError: Error {
    case invalidSize
}

func encodeSnapshot<T>(_ value: T) -> Data {
        var localValue = value
    return withUnsafePointer(to: &localValue) { p in
        Data(bytes: p, count: MemoryLayout.size(ofValue: value))
    }
}

func decodeSnapshot<T>(_ data: Data) throws -> T {
    guard data.count == MemoryLayout<T>.size else {
        throw EncodingStructError.invalidSize
    }
    
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: MemoryLayout<T.Type>.size)
    (data as NSData).getBytes(pointer, length: data.count)
    
    return pointer.move()
}

// In contrast to the GCController implementation of snapshots, we
// do not descend from our VgcExtendedGamepad, and instead create a
// fresh class that reads from the profile.  Because we read through
// the public interface, the values are automagically relative to
// whether it is a software or hardware controller.

// MARK: - Extended Gamepad Snapshot

open class VgcExtendedGamepadSnapshot: NSObject {
 
    fileprivate let elements = VgcManager.elements
    
    // Use a custom named version of the snapshot struct
    struct VgcExtendedGamepadSnapShotDataV100 {
        var version: UInt16
        var size: UInt16
        var dpadX: Float
        var dpadY: Float
        var buttonA: Float
        var buttonB: Float
        var buttonX: Float
        var buttonY: Float
        var leftShoulder: Float
        var rightShoulder: Float
        var leftThumbstickX: Float
        var leftThumbstickY: Float
        var rightThumbstickX: Float
        var rightThumbstickY: Float
        var leftTrigger: Float
        var rightTrigger: Float
    }
    
    fileprivate var controller: VgcController!
    
    var snapshotV100Structure: VgcExtendedGamepadSnapShotDataV100!
    
    public init(controller: VgcController) {
        
        self.controller = controller
        
        // Create our interal struct where we hold the snapped values.  This
        // struct will be used to provide interface-based access to the data
        // (using the getters below) as well as generating the NSData representation
        // of the snapshot.
        let sizeInt = MemoryLayout<VgcExtendedGamepadSnapShotDataV100>.size
        let sizeUInt16 = UInt16(sizeInt)
        snapshotV100Structure = VgcExtendedGamepadSnapShotDataV100(
            version: 0x0100,
            size: sizeUInt16,
            dpadX: (controller.extendedGamepad?.dpad.xAxis.value)!,
            dpadY: (controller.extendedGamepad?.dpad.yAxis.value)!,
            buttonA: (controller.extendedGamepad?.buttonA.value)!,
            buttonB: (controller.extendedGamepad?.buttonB.value)!,
            buttonX: (controller.extendedGamepad?.buttonX.value)!,
            buttonY: (controller.extendedGamepad?.buttonY.value)!,
            leftShoulder: (controller.extendedGamepad?.leftShoulder.value)!,
            rightShoulder: (controller.extendedGamepad?.rightShoulder.value)!,
            leftThumbstickX: (controller.extendedGamepad?.leftThumbstick.xAxis.value)!,
            leftThumbstickY: (controller.extendedGamepad?.leftThumbstick.yAxis.value)!,
            rightThumbstickX: (controller.extendedGamepad?.rightThumbstick.xAxis.value)!,
            rightThumbstickY: (controller.extendedGamepad?.rightThumbstick.yAxis.value)!,
            leftTrigger: (controller.extendedGamepad?.leftTrigger.value)!,
            rightTrigger: (controller.extendedGamepad?.rightTrigger.value)!
        )
        super.init()
    }
    
    public init(controller: VgcController, snapshotData: Data) {
        
        super.init()
        
        self.controller = controller
        
        // This will trigger both populating the V100 structure and updating
        // the elements of the above controller
        self.snapshotData = snapshotData
        
    }
    
    public init(snapshotData: Data) { super.init(); self.snapshotData = snapshotData }
    
    // Getters for the various elements that read from the struct
    open var dpad: GCControllerDirectionPad { get { return makeDirectionPad(snapshotV100Structure.dpadX, yAxis: snapshotV100Structure.dpadY, controller: controller, xElement: elements.dpadXAxis, yElement: elements.dpadYAxis) } }
    open var buttonA: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.buttonA, controller: controller, element: elements.buttonA) } }
    open var buttonB: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.buttonB, controller: controller, element: elements.buttonB) } }
    open var buttonX: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.buttonX, controller: controller, element: elements.buttonX) } }
    open var buttonY: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.buttonY, controller: controller, element: elements.buttonY) } }
    open var leftShoulder: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.rightShoulder, controller: controller, element: elements.leftShoulder) } }
    open var rightShoulder: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.leftShoulder, controller: controller, element: elements.rightShoulder) } }
    open var leftTrigger: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.leftTrigger, controller: controller, element: elements.leftTrigger) } }
    open var rightTrigger: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.rightTrigger, controller: controller, element: elements.rightTrigger) } }
    open var rightThumbstick: GCControllerDirectionPad { get { return makeDirectionPad(snapshotV100Structure.rightThumbstickX, yAxis: snapshotV100Structure.rightThumbstickY, controller: controller, xElement: elements.rightThumbstickXAxis, yElement: elements.rightThumbstickYAxis) } }
    open var leftThumbstick: GCControllerDirectionPad { get { return makeDirectionPad(snapshotV100Structure.leftThumbstickX, yAxis: snapshotV100Structure.leftThumbstickY, controller: controller, xElement: elements.dpadXAxis, yElement: elements.dpadYAxis) } }
    
    
    // The user can both read and write to the snapshotData property, NSData, that represents
    // an archived or flattened for of the snapshot object.  It is the way to "rehydrate" a
    // previously saved object, and results in "transmission" to the associated controller.
    
    open var snapshotData: Data {
        
        get {
            
            let snapshot = UnsafeMutablePointer<VgcExtendedGamepadSnapShotDataV100>.allocate(capacity: 1)
            snapshot.initialize(to: snapshotV100Structure)
            let encodedNSData = encodeSnapshot(snapshotV100Structure)
            return encodedNSData
        }
        
        set {
            
            // Decode the incoming NSData into the V100 structure
            do {
                snapshotV100Structure = try decodeSnapshot(newValue)
            } catch {
                print(error)
            }
            
            // Copy V100 structure into the profile values.  May be nil if
            // the simple init is used
            guard controller == nil else {
                
                controller.elements.dpadXAxis.value = snapshotV100Structure.dpadX as AnyObject
                controller.elements.dpadYAxis.value = snapshotV100Structure.dpadY as AnyObject
                
                controller.elements.buttonA.value = snapshotV100Structure.buttonA as AnyObject
                controller.elements.buttonB.value = snapshotV100Structure.buttonB as AnyObject
                controller.elements.buttonX.value = snapshotV100Structure.buttonX as AnyObject
                controller.elements.buttonY.value = snapshotV100Structure.buttonY as AnyObject
                
                controller.elements.leftShoulder.value = snapshotV100Structure.leftShoulder as AnyObject
                controller.elements.rightShoulder.value = snapshotV100Structure.rightShoulder as AnyObject
                
                controller.elements.rightThumbstickXAxis.value = snapshotV100Structure.rightThumbstickX as AnyObject
                controller.elements.rightThumbstickYAxis.value = snapshotV100Structure.rightThumbstickY as AnyObject
                
                controller.elements.leftThumbstickXAxis.value = snapshotV100Structure.leftThumbstickX as AnyObject
                controller.elements.leftThumbstickYAxis.value = snapshotV100Structure.leftThumbstickY as AnyObject
                
                controller.elements.rightTrigger.value = snapshotV100Structure.rightTrigger as AnyObject
                controller.elements.leftTrigger.value = snapshotV100Structure.leftTrigger as AnyObject
                
                return
            }
        }
    }
    
}

// MARK: - Gamepad Snapshot
open class VgcGamepadSnapshot: NSObject {

    fileprivate let elements = VgcManager.elements
    
    // Use a custom named version of the snapshot struct
    struct VgcGamepadSnapShotDataV100 {
        var version: UInt16
        var size: UInt16
        var dpadX: Float
        var dpadY: Float
        var buttonA: Float
        var buttonB: Float
        var buttonX: Float
        var buttonY: Float
        var leftShoulder: Float
        var rightShoulder: Float
        
    }
    
    fileprivate var controller: VgcController!
    
    var snapshotV100Structure: VgcGamepadSnapShotDataV100!
    
    public init(controller: VgcController) {
        
        self.controller = controller
        
        // Create our interal struct where we hold the snapped values.  This
        // struct will be used to provide interface-based access to the data
        // (using the getters below) as well as generating the NSData representation
        // of the snapshot.
        let sizeInt = MemoryLayout<VgcGamepadSnapShotDataV100>.size
        let sizeUInt16 = UInt16(sizeInt)
        snapshotV100Structure = VgcGamepadSnapShotDataV100(
            version: 0x0100,
            size: sizeUInt16,
            dpadX: (controller.gamepad?.dpad.xAxis.value)!,
            dpadY: (controller.gamepad?.dpad.yAxis.value)!,
            buttonA: (controller.gamepad?.buttonA.value)!,
            buttonB: (controller.gamepad?.buttonB.value)!,
            buttonX: (controller.gamepad?.buttonX.value)!,
            buttonY: (controller.gamepad?.buttonY.value)!,
            leftShoulder: (controller.gamepad?.leftShoulder.value)!,
            rightShoulder: (controller.gamepad?.rightShoulder.value)!
        )
        super.init()
    }
    
    public init(controller: VgcController, snapshotData: Data) {
        
        super.init()
        
        self.controller = controller
        
        // This will trigger both populating the V100 structure and updating
        // the elements of the above controller
        self.snapshotData = snapshotData
        
    }
    
    public init(snapshotData: Data) { super.init(); self.snapshotData = snapshotData }
    
    // Getters for the various elements that read from the struct
    open var dpad: GCControllerDirectionPad { get { return makeDirectionPad(snapshotV100Structure.dpadX, yAxis: snapshotV100Structure.dpadY, controller: controller, xElement: elements.dpadXAxis, yElement: elements.dpadYAxis) } }
    open var buttonA: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.buttonA, controller: controller, element: elements.buttonA) } }
    open var buttonB: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.buttonB, controller: controller, element: elements.buttonB) } }
    open var buttonX: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.buttonX, controller: controller, element: elements.buttonX) } }
    open var buttonY: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.buttonY, controller: controller, element: elements.buttonY) } }
    open var leftShoulder: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.rightShoulder, controller: controller, element: elements.leftShoulder) } }
    open var rightShoulder: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.leftShoulder, controller: controller, element: elements.rightShoulder) } }
    
    // The user can both read and write to the snapshotData property, NSData, that represents
    // an archived or flattened for of the snapshot object.  It is the way to "rehydrate" a
    // previously saved object, and results in "transmission" to the associated controller.
    
    open var snapshotData: Data {
        
        get {
            
            let snapshot = UnsafeMutablePointer<VgcGamepadSnapShotDataV100>.allocate(capacity: 1)
            snapshot.initialize(to: snapshotV100Structure)
            let encodedNSData = encodeSnapshot(snapshotV100Structure)
            return encodedNSData
        }
        
        set {
            
            // Decode the incoming NSData into the V100 structure
            do {
                snapshotV100Structure = try decodeSnapshot(newValue)
            } catch {
                print(error)
            }
            
            // Copy V100 structure into the profile values.  May be nil if
            // the simple init is used
            guard controller == nil else {
                controller.vgcExtendedGamepad?.vgcDpad.vgcXAxis.value = snapshotV100Structure.dpadX
                controller.vgcExtendedGamepad?.vgcDpad.vgcYAxis.value = snapshotV100Structure.dpadY
                
                controller.vgcExtendedGamepad?.vgcButtonA.value = snapshotV100Structure.buttonA
                controller.vgcExtendedGamepad?.vgcButtonB.value = snapshotV100Structure.buttonB
                controller.vgcExtendedGamepad?.vgcButtonX.value = snapshotV100Structure.buttonX
                controller.vgcExtendedGamepad?.vgcButtonY.value = snapshotV100Structure.buttonY
                
                controller.vgcExtendedGamepad?.vgcLeftShoulder.value = snapshotV100Structure.leftShoulder
                controller.vgcExtendedGamepad?.vgcRightShoulder.value = snapshotV100Structure.rightShoulder
                
                return
            }
        }
    }
}

#if os(tvOS)
// MARK: - MicroGamepad Snapshot
public class VgcMicroGamepadSnapshot: NSObject {
 
    private let elements = VgcManager.elements
    
    // Use a custom named version of the snapshot struct
    struct VgcMicroGamepadSnapShotDataV100 {
        var version: UInt16
        var size: UInt16
        var dpadX: Float
        var dpadY: Float
        var buttonA: Float
        var buttonX: Float
        
    }
    
    private var controller: VgcController!
    
    var snapshotV100Structure: VgcMicroGamepadSnapShotDataV100!
    
    public init(controller: VgcController) {
        
        self.controller = controller
        
        // Create our internal struct where we hold the snapped values.  This
        // struct will be used to provide interface-based access to the data
        // (using the getters below) as well as generating the NSData representation
        // of the snapshot.
        let sizeInt = MemoryLayout<VgcMicroGamepadSnapShotDataV100>.size
        let sizeUInt16 = UInt16(sizeInt)
        snapshotV100Structure = VgcMicroGamepadSnapShotDataV100(
            version: 0x0100,
            size: sizeUInt16,
            dpadX: (controller.microGamepad?.dpad.xAxis.value)!,
            dpadY: (controller.microGamepad?.dpad.yAxis.value)!,
            buttonA: (controller.microGamepad?.buttonA.value)!,
            buttonX: (controller.microGamepad?.buttonX.value)!
        )
        super.init()
    }
    
    public init(controller: VgcController, snapshotData: NSData) {
        
        super.init()
        
        self.controller = controller
        
        // This will trigger both populating the V100 structure and updating
        // the elements of the above controller
        self.snapshotData = snapshotData
        
    }
    
    public init(snapshotData: NSData) { super.init(); self.snapshotData = snapshotData }
    
    // Getters for the various elements that read from the struct
    public var dpad: GCControllerDirectionPad { get { return makeDirectionPad(snapshotV100Structure.dpadX, yAxis: snapshotV100Structure.dpadY, controller: controller, xElement: elements.dpadXAxis, yElement: elements.dpadYAxis) } }
    public var buttonA: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.buttonA, controller: controller, element: elements.buttonA) } }
    public var buttonX: GCControllerButtonInput { get { return makeButton(snapshotV100Structure.buttonX, controller: controller, element: elements.buttonX) } }
    
    // The user can both read and write to the snapshotData property, NSData, that represents
    // an archived or flattened for of the snapshot object.  It is the way to "rehydrate" a
    // previously saved object, and results in "transmission" to the associated controller.
    
    public var snapshotData: NSData {
        
        get {
            
            let snapshot = UnsafeMutablePointer<VgcMicroGamepadSnapShotDataV100>.allocate(capacity: 1)
            snapshot.initialize(to: snapshotV100Structure)
            let encodedNSData = encodeSnapshot(snapshotV100Structure)
            return encodedNSData as NSData
        }
        
        set {
            
            // Decode the incoming NSData into the V100 structure
            do {
                snapshotV100Structure = try decodeSnapshot(newValue as Data)
            } catch {
                print(error)
            }
            
            // Copy V100 structure into the profile values.  May be nil if
            // the simple init is used
            guard controller == nil else {
                controller.vgcExtendedGamepad?.vgcDpad.vgcXAxis.value = snapshotV100Structure.dpadX
                controller.vgcExtendedGamepad?.vgcDpad.vgcYAxis.value = snapshotV100Structure.dpadY
                
                controller.vgcExtendedGamepad?.vgcButtonA.value = snapshotV100Structure.buttonA
                controller.vgcExtendedGamepad?.vgcButtonX.value = snapshotV100Structure.buttonX
                
                return
            }
        }
    }
}
    #endif

// MARK: - Profile components

class VgcControllerButtonInput: GCControllerButtonInput {
    
    fileprivate var vgcGameController: VgcController?
    fileprivate var element: Element!
    fileprivate var vgcValueChangedHandler: GCControllerButtonValueChangedHandler?
    fileprivate var vgcPressedChangedHandler: GCControllerButtonValueChangedHandler?
    fileprivate var vgcButtonPressed: Bool = false
    
    //internal typealias VgcControllerButtonValueChangedHandler = (VgcControllerButtonInput, Float, Bool) -> Void
    
    init(vgcGameController: VgcController, element: Element) {
        
        self.element = element
        self.vgcGameController = vgcGameController
        
        super.init()
        
    }
    

    override var isPressed: Bool {
        get {
            return vgcButtonPressed
        }
    }
    
    override var value: Float {
        
        get {
            return (element.value).floatValue!
        }
        set {
            
            element.value = newValue as AnyObject
            
            var buttonPressedChanged = false
            
            if !vgcButtonPressed && newValue != 0.0 {
                vgcButtonPressed = true
                buttonPressedChanged = true
            } else if vgcButtonPressed && newValue == 0.0 {
                vgcButtonPressed = false
                buttonPressedChanged = true
            }

            if buttonPressedChanged {
                if let pressedChangedHandler = vgcPressedChangedHandler {
                    (vgcGameController?.handlerQueue)!.async {
                        pressedChangedHandler(self, newValue, self.vgcButtonPressed)
                    }
                }
            }
            
            if let valueHandler = vgcValueChangedHandler {
                (vgcGameController?.handlerQueue)!.async {
                    valueHandler(self, self.element.value.floatValue, self.vgcButtonPressed)
                }
            }
            
            vgcGameController?.callProfileLevelChangeHandler(self)
        }
    }
    
    override var valueChangedHandler: GCControllerButtonValueChangedHandler? {
        get {
            return vgcValueChangedHandler!
        }
        set {
            vgcValueChangedHandler = newValue
        }
    }
    
    override var pressedChangedHandler: GCControllerButtonValueChangedHandler? {
        get {
            return vgcPressedChangedHandler!
        }
        set {
            vgcPressedChangedHandler = newValue
        }
    }
}

// Custom impelmentation of GCControllerAxisInput
class VgcControllerAxisInput: GCControllerAxisInput {
    
    fileprivate var vgcGameController: VgcController?
    fileprivate var element: Element!
    fileprivate var vgcCollection: VgcControllerDirectionPad?
    fileprivate var vgcValueChangedHandler: GCControllerAxisValueChangedHandler?
    
    init(vgcGameController: VgcController, element: Element) {
        
        self.vgcGameController = vgcGameController
        self.element = element
        super.init()
        
    }
    
    override var collection: GCControllerElement? { get { return (vgcCollection! as GCControllerElement) } }
    
    override var value: Float {
        get {
            if let floatValue = element.value.floatValue {
                return floatValue
            } else {
                return 0
            }
        }
        set {
            if let handler = vgcValueChangedHandler {
                (vgcGameController?.handlerQueue)!.async {
                    handler(self, newValue)
                }
            }
            vgcCollection?.callHandler()
            
            vgcGameController?.callProfileLevelChangeHandler(self)
            
        }
    }
    
    override var valueChangedHandler: GCControllerAxisValueChangedHandler? {
        get {
            return vgcValueChangedHandler!
        }
        set {
            vgcValueChangedHandler = newValue
        }
    }
    
}

class VgcControllerDirectionPad: GCControllerDirectionPad {
    
    fileprivate var vgcGameController: VgcController?
    fileprivate var vgcXAxis: VgcControllerAxisInput!
    fileprivate var vgcYAxis: VgcControllerAxisInput!
    fileprivate var vgcValueChangedHandler: GCControllerDirectionPadValueChangedHandler?
    
    init(vgcGameController: VgcController, xElement: Element, yElement: Element) {
        
        self.vgcGameController = vgcGameController
        vgcXAxis = VgcControllerAxisInput(vgcGameController: vgcGameController, element: xElement)
        vgcYAxis = VgcControllerAxisInput(vgcGameController: vgcGameController, element: yElement)
        super.init()
        vgcXAxis.vgcCollection = self
        vgcYAxis.vgcCollection = self
        
    }
    
    func callHandler() {
        if let hanlder = vgcValueChangedHandler {
            (vgcGameController?.handlerQueue)!.async {
                hanlder(self, self.vgcXAxis.value, self.vgcYAxis.value)
            }
        }
        
    }
    
    @objc override var xAxis: VgcControllerAxisInput {
        get {
            return vgcXAxis
        }
        set {
            
            vgcXAxis = newValue
            callHandler()
            
            vgcGameController?.callProfileLevelChangeHandler(self)
        }
    }
    
    @objc override var yAxis: VgcControllerAxisInput {
        get {
            return vgcYAxis
        }
        set {
            
            vgcYAxis = newValue
            callHandler()
            
            vgcGameController?.callProfileLevelChangeHandler(self)
        }
    }
    
     @objc override var valueChangedHandler: GCControllerDirectionPadValueChangedHandler? {
        get {
            return vgcValueChangedHandler!
        }
        set {
            vgcValueChangedHandler = newValue
        }
    }
}
    
class VgcFloatValue: NSObject {
    
    var value: Float = 0.0
    
}

#endif




