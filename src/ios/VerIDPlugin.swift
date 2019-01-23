import UIKit
import VerID

@objc(VerIDPlugin) public class VerIDPlugin: CDVPlugin, VerIDSessionDelegate {
    
    private var veridSessionCallbackId: String?
    
    @objc public func load(_ command: CDVInvokedUrlCommand) {
        self.loadVerID(command) {
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK), callbackId: command.callbackId)
        }
    }
    
    @objc public func unload(_ command: CDVInvokedUrlCommand) {
        VerID.shared.unload()
        self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK), callbackId: command.callbackId)
    }
    
    @objc public func registerUser(_ command: CDVInvokedUrlCommand) {
        self.startSessionWithType(VerIDRegistrationSession.self, command: command)
    }
    
    @objc public func authenticate(_ command: CDVInvokedUrlCommand) {
        self.startSessionWithType(VerIDAuthenticationSession.self, command: command)
    }
    
    @objc public func captureLiveFace(_ command: CDVInvokedUrlCommand) {
        self.startSessionWithType(VerIDLivenessDetectionSession.self, command: command)
    }
    
    @objc public func getRegisteredUsers(_ command: CDVInvokedUrlCommand) {
        commandDelegate.run {
            do {
                let users = try VerID.shared.registeredVerIDUsers()
                if let usersString = String(data: try JSONEncoder().encode(users), encoding: .utf8) {
                    DispatchQueue.main.async {
                        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: usersString)
                        self.commandDelegate.send(result, callbackId: command.callbackId)
                    }
                    return
                }
            } catch {
            }
            DispatchQueue.main.async {
                self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR), callbackId: command.callbackId)
            }
        }
    }
    
    @objc public func deleteUser(_ command: CDVInvokedUrlCommand) {
        if let userId = command.arguments?.compactMap({ ($0 as? [String:String])?["userId"] }).first {
            commandDelegate.run {
                VerID.shared.deregisterUser(userId)
                let result = CDVPluginResult(status: CDVCommandStatus_OK)
                DispatchQueue.main.async {
                    self.commandDelegate.send(result, callbackId: command.callbackId)
                }
            }
        } else {
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR), callbackId: command.callbackId)
        }
    }

    @objc public func compareFaceTemplates(_ command: CDVInvokedUrlCommand) {
        if let t1 = command.arguments?.compactMap({ ($0 as? [String:String])?["template1"] }).first?.data(using: .utf8), let t2 = command.arguments?.compactMap({ ($0 as? [String:String])?["template2"] }).first?.data(using: .utf8) {
            commandDelegate.run {
                do {
                    let template1 = try JSONDecoder().decode(FaceTemplate.self, from: t1)
                    let template2 = try JSONDecoder().decode(FaceTemplate.self, from: t2)
                    let score = try FaceUtil.compareFaceTemplate(template1, to: template2).floatValue
                    DispatchQueue.main.async {
                        let message: [String:Any] = ["score":score];
                        self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK, messageAs: message), callbackId: command.callbackId)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR), callbackId: command.callbackId)
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR), callbackId: command.callbackId)
            }
        }
    }
    
    @objc public func detectFaceInImage(_ command: CDVInvokedUrlCommand) {
        self.loadVerID(command) {
            self.commandDelegate.run(inBackground: {
                do {
                    guard let imageString = command.arguments?.compactMap({ ($0 as? [String:String])?["image"] }).first else {
                        throw VerIDPluginError.invalidArgument
                    }
                    guard imageString.starts(with: "data:image/"), let mimeTypeEndIndex = imageString.firstIndex(of: ";"), let dataIndex = imageString.firstIndex(of: ",") else {
                        throw VerIDPluginError.invalidArgument
                    }
                    guard String(imageString[mimeTypeEndIndex..<imageString.index(mimeTypeEndIndex, offsetBy: 6)]) == "base64" else {
                        throw VerIDPluginError.invalidArgument
                    }
                    guard let data = Data(base64Encoded: String(imageString[dataIndex...])) else {
                        throw VerIDPluginError.invalidArgument
                    }
                    guard let image = UIImage(data: data) else {
                        throw VerIDPluginError.invalidArgument
                    }
                    let face = try VerID.shared.detectFaceInImage(image, keepForRecognition: true)
                    guard let encodedFace = String(data: try JSONEncoder().encode(face), encoding: .utf8) else {
                        throw VerIDPluginError.encodingError
                    }
                    DispatchQueue.main.async {
                        self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK, messageAs: encodedFace), callbackId: command.callbackId)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.localizedDescription), callbackId: command.callbackId)
                    }
                }
            })
        }
    }
    
    // MARK: - VerID Session Delegate
    
    public func session(_ session: VerIDSession, didFinishWithResult result: VerIDSessionResult) {
        guard let callbackId = self.veridSessionCallbackId, !callbackId.isEmpty else {
            return
        }
        self.veridSessionCallbackId = nil
        self.commandDelegate.run {
            do {
                if let message = String(data: try JSONEncoder().encode(result), encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK, messageAs: message), callbackId: callbackId)
                    }
                    return
                }
            } catch {
            }
            DispatchQueue.main.async {
                self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR), callbackId: callbackId)
            }
        }
    }
    
    
    // MARK: - Session helpers
    
    private func createSettings<T: VerIDSessionSettings>(_ args: [Any]?) throws -> T {
        guard let string = args?.compactMap({ ($0 as? [String:String])?["settings"] }).first, let data = string.data(using: .utf8) else {
            NSLog("Unable to parse settings")
            throw VerIDPluginError.parsingError
        }
        let settings = try JSONDecoder().decode(T.self, from: data)
        NSLog("Decoded settings %@ from %@", String(describing: T.self), string)
        return settings
    }
    
    private func defaultSettings<T: VerIDSessionSettings>() -> T {
        switch T.self {
        case is VerIDRegistrationSessionSettings.Type:
            return VerIDRegistrationSessionSettings() as! T
        case is VerIDAuthenticationSessionSettings.Type:
            return VerIDAuthenticationSessionSettings() as! T
        case is VerIDLivenessDetectionSessionSettings.Type:
            return VerIDLivenessDetectionSessionSettings() as! T
        default:
            return VerIDSessionSettings() as! T
        }
    }
    
    private func startSessionWithType<T: VerIDSession>(_ type: T.Type, command: CDVInvokedUrlCommand) {
        guard self.veridSessionCallbackId == nil || self.veridSessionCallbackId!.isEmpty else {
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR), callbackId: command.callbackId)
            return
        }
        self.loadVerID(command) {
            let veridSession: VerIDSession
            do {
                switch type {
                case is VerIDRegistrationSession.Type:
                    let regSessionSettings: VerIDRegistrationSessionSettings = try self.createSettings(command.arguments)
                    veridSession = VerIDRegistrationSession(settings: regSessionSettings)
                case is VerIDAuthenticationSession.Type:
                    let authSessionSettings: VerIDAuthenticationSessionSettings = try self.createSettings(command.arguments)
                    veridSession = VerIDAuthenticationSession(settings: authSessionSettings)
                case is VerIDLivenessDetectionSession.Type:
                    let livenessSessionSettings: VerIDLivenessDetectionSessionSettings = try self.createSettings(command.arguments)
                    veridSession = VerIDLivenessDetectionSession(settings: livenessSessionSettings)
                default:
                    veridSession = VerIDSession()
                }
            } catch {
                self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR), callbackId: command.callbackId)
                return
            }
            self.veridSessionCallbackId = command.callbackId
            veridSession.delegate = self
            veridSession.start()
        }
    }
    
    func loadVerID(_ command: CDVInvokedUrlCommand, callback: @escaping () -> Void) {
        let apiSecret = command.arguments?.compactMap({ ($0 as? [String:String])?["apiSecret"] }).first
        if !VerID.shared.isLoaded {
            VerID.shared.load(apiSecret) { (success, error) in
                if error == nil && success {
                    callback()
                } else {
                    self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR), callbackId: command.callbackId)
                }
            }
        } else {
            callback()
        }
    }
}

public enum VerIDPluginError: Int, Error {
    case parsingError, invalidArgument, encodingError
}
