import UIKit
import VerIDCore
import VerIDUI

@objc(VerIDPlugin) public class VerIDPlugin: CDVPlugin, VerIDFactoryDelegate, VerIDSessionDelegate {
    
    private var veridSessionCallbackId: String?
    private var verid: VerID?
    private var TESTING_MODE: Bool = false
    
    @objc public func load(_ command: CDVInvokedUrlCommand) {
        self.loadVerID(command) { _ in
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK), callbackId: command.callbackId)
        }
    }
    
    @objc public func unload(_ command: CDVInvokedUrlCommand) {
        self.verid = nil
        self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK, messageAs: "OK"), callbackId: command.callbackId)
    }
    
    @objc public func registerUser(_ command: CDVInvokedUrlCommand) {
        if self.TESTING_MODE {
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK, messageAs: self.getAttachmentMockup()), callbackId: command.callbackId)
        } else {
            do {
                let settings: RegistrationSessionSettings = try self.createSettings(command.arguments)
                self.startSession(command: command, settings: settings)
            } catch {
                self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.localizedDescription), callbackId: command.callbackId)
            }
        }
    }
    
    @objc public func authenticate(_ command: CDVInvokedUrlCommand) {
        if self.TESTING_MODE {
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK, messageAs: self.getAttachmentMockup()), callbackId: command.callbackId)
        } else {
            do {
                let settings: AuthenticationSessionSettings = try self.createSettings(command.arguments)
                self.startSession(command: command, settings: settings)
            } catch {
                self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.localizedDescription), callbackId: command.callbackId)
            }
        }
    }
    
    @objc public func captureLiveFace(_ command: CDVInvokedUrlCommand) {
        if self.TESTING_MODE {
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK, messageAs: self.getAttachmentMockup()), callbackId: command.callbackId)
        } else {
            do {
                let settings: LivenessDetectionSessionSettings = try self.createSettings(command.arguments)
                self.startSession(command: command, settings: settings)
            } catch {
                self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.localizedDescription), callbackId: command.callbackId)
            }
        }
    }
    
    @objc public func getRegisteredUsers(_ command: CDVInvokedUrlCommand) {
        self.loadVerID(command) { verid in
            var err: String = "Unknown error"
            do {
                let users = try verid.userManagement.users()
                if let usersString = String(data: try JSONEncoder().encode(users), encoding: .utf8) {
                    let usersResult = self.TESTING_MODE ? "[\"user1\", \"user2\", \"user3\"]" : usersString;
                    let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: usersResult)
                    self.commandDelegate.send(result, callbackId: command.callbackId)
                    return
                } else {
                    err = "Failed to encode JSON as UTF-8 string"
                }
            } catch {
                err = error.localizedDescription
            }
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: err), callbackId: command.callbackId)
        }
    }
    
    @objc public func deleteUser(_ command: CDVInvokedUrlCommand) {
        if let userId = command.arguments?.compactMap({ ($0 as? [String:String])?["userId"] }).first {
            self.loadVerID(command) { verid in
                verid.userManagement.deleteUsers([userId]) { error in
                    if let err = error {
                        self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: err.localizedDescription), callbackId: command.callbackId)
                        return
                    }
                    let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: "OK")
                    self.commandDelegate.send(result, callbackId: command.callbackId)
                }
            }
        } else {
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Unable to parse userId argument"), callbackId: command.callbackId)
        }
    }
    
    @objc public func compareFaces(_ command: CDVInvokedUrlCommand) {
        if let t1 = command.arguments?.compactMap({ ($0 as? [String:String])?["face1"] }).first?.data(using: .utf8), let t2 = command.arguments?.compactMap({ ($0 as? [String:String])?["face2"] }).first?.data(using: .utf8) {
            self.loadVerID(command) { verid in
                self.commandDelegate.run {
                    do {
                        if let template1 = try JSONDecoder().decode(CodableFace.self, from: t1).recognizable,
                        let template2 = try JSONDecoder().decode(CodableFace.self, from: t2).recognizable {
                            let score = try verid.faceRecognition.compareSubjectFaces([template1], toFaces: [template2]).floatValue
                            DispatchQueue.main.async {
                                let message: [String:Any] = ["score":score,"authenticationThreshold":verid.faceRecognition.authenticationScoreThreshold.floatValue,"max":verid.faceRecognition.maxAuthenticationScore.floatValue];
                                self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK, messageAs: message), callbackId: command.callbackId)
                            }
                        } else {
                            DispatchQueue.main.async {
                               self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Unable to parse template1 and/or template2 arguments"), callbackId: command.callbackId)
                            }
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.localizedDescription), callbackId: command.callbackId)
                        }
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Unable to parse template1 and/or template2 arguments"), callbackId: command.callbackId)
            }
        }
    }
    
    @objc public func detectFaceInImage(_ command: CDVInvokedUrlCommand) {
        self.loadVerID(command) { verid in
            self.commandDelegate.run(inBackground: {
                do {
                    guard let imageString = command.arguments?.compactMap({ ($0 as? [String:String])?["image"] }).first else {
                        throw VerIDPluginError.invalidArgument
                    }
                    guard imageString.starts(with: "data:image/"), let mimeTypeEndIndex = imageString.firstIndex(of: ";"), let commaIndex = imageString.firstIndex(of: ",") else {
                        throw VerIDPluginError.invalidArgument
                    }
                    let dataIndex = imageString.index(commaIndex, offsetBy: 1)
                    guard String(imageString[mimeTypeEndIndex..<imageString.index(mimeTypeEndIndex, offsetBy: 7)]) == ";base64" else {
                        throw VerIDPluginError.invalidArgument
                    }
                    guard let data = Data(base64Encoded: String(imageString[dataIndex...])) else {
                        throw VerIDPluginError.invalidArgument
                    }
                    guard let image = UIImage(data: data), let cgImage = image.cgImage else {
                        throw VerIDPluginError.invalidArgument
                    }
                    let orientation: CGImagePropertyOrientation
                    switch image.imageOrientation {
                    case .up:
                        orientation = .up
                    case .down:
                        orientation = .down
                    case .left:
                        orientation = .left
                    case .right:
                        orientation = .right
                    case .upMirrored:
                        orientation = .upMirrored
                    case .downMirrored:
                        orientation = .downMirrored
                    case .leftMirrored:
                        orientation = .leftMirrored
                    case .rightMirrored:
                        orientation = .rightMirrored
                    @unknown default:
                        orientation = .up
                    }
                    let veridImage = VerIDImage(cgImage: cgImage, orientation: orientation)
                    let faces = try verid.faceDetection.detectFacesInImage(veridImage, limit: 1, options: 0)
                    guard let recognizableFace = try verid.faceRecognition.createRecognizableFacesFromFaces(faces, inImage: veridImage).first else {
                        throw VerIDPluginError.faceTemplateExtractionError
                    }
                    let encodableFace = CodableFace(face: faces[0], recognizable: recognizableFace)
                    guard let encodedFace = String(data: try JSONEncoder().encode(encodableFace), encoding: .utf8) else {
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
            var err = "Unknown error"
            do {
                if let message = String(data: try JSONEncoder().encode(CodableSessionResult(result)), encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK, messageAs: message), callbackId: callbackId)
                    }
                    return
                } else {
                    err = "Unabe to encode JSON as UTF-8 string"
                }
            } catch {
                err = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: err), callbackId: callbackId)
            }
        }
    }
    
    public func sessionWasCanceled(_ session: VerIDSession) {
        guard let callbackId = self.veridSessionCallbackId else {
            return
        }
        self.veridSessionCallbackId = nil
        self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK), callbackId: callbackId)
    }
    
    
    // MARK: - Session helpers
    
    private func createSettings<T: VerIDSessionSettings>(_ args: [Any]?) throws -> T {
        guard let string = args?.compactMap({ ($0 as? [String:String])?["settings"] }).first, let data = string.data(using: .utf8) else {
            NSLog("Unable to parse settings")
            throw VerIDPluginError.parsingError
        }
        let settings: T = try JSONDecoder().decode(T.self, from: data)
        NSLog("Decoded settings %@ from %@", String(describing: T.self), string)
        return settings
    }
    
    private func defaultSettings<T: VerIDSessionSettings>() -> T {
        switch T.self {
        case is RegistrationSessionSettings.Type:
            return RegistrationSessionSettings(userId: "default") as! T
        case is AuthenticationSessionSettings.Type:
            return AuthenticationSessionSettings(userId: "default") as! T
        case is LivenessDetectionSessionSettings.Type:
            return LivenessDetectionSessionSettings() as! T
        default:
            return VerIDSessionSettings() as! T
        }
    }
    
    private func startSession<T: VerIDSessionSettings>(command: CDVInvokedUrlCommand, settings: T) {
        guard self.veridSessionCallbackId == nil || self.veridSessionCallbackId!.isEmpty else {
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR), callbackId: command.callbackId)
            return
        }
        self.loadVerID(command) { verid in
            self.veridSessionCallbackId = command.callbackId
            let session = VerIDSession(environment: verid, settings: settings)
            session.delegate = self
            session.start()
        }
    }
    
    func loadVerID(_ command: CDVInvokedUrlCommand, callback: @escaping (VerID) -> Void) {
        if let verid = self.verid {
            callback(verid)
            return
        }
        self.veridSessionCallbackId = command.callbackId
        let veridFactory: VerIDFactory
        if let password = command.arguments?.compactMap({ ($0 as? [String:String])?["password"] }).first {
            veridFactory = VerIDFactory(veridPassword: password)
        } else {
            veridFactory = VerIDFactory()
        }
        veridFactory.delegate = self
        veridFactory.createVerID()
    }
    
    public func veridFactory(_ factory: VerIDFactory, didCreateVerID instance: VerID) {
        if let callbackId = self.veridSessionCallbackId {
            self.veridSessionCallbackId = nil
            self.verid = instance
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK), callbackId: callbackId)
        }
    }
    
    public func veridFactory(_ factory: VerIDFactory, didFailWithError error: Error) {
        if let callbackId = self.veridSessionCallbackId {
            self.veridSessionCallbackId = nil
            self.verid = nil
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.localizedDescription), callbackId: callbackId)
        }
    }
    //Start Methods For Testing
    
    //Cordova action: setTestingMode
    @objc public func setTestingMode(_ command: CDVInvokedUrlCommand) {
        if let mode: Bool = command.arguments[0] as? Bool {
            NSLog("SetTestingMode Called:" + mode.description)
            self.TESTING_MODE = mode
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_OK), callbackId: command.callbackId)
        } else {
            self.commandDelegate.send(CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Not or Invalid Argutments provided"), callbackId: command.callbackId)
        }
    }
    
    //Functions to get Mockup data
    
    private func getAttachmentMockup() -> String {
        let faceMockup : String = self.getFaceMockup()
        var mockup = "{\"attachments\": [";
        mockup += "{\"recognizableFace\": " + faceMockup + ", \"image\": \"TESTING_IMAGE\", \"bearing\": \"STRAIGHT\"}";
        mockup += "]}";
        
        return mockup
    }
    
    private func getFaceMockup() -> String {
        var faceMockup : String = "{\"x\":-8.384888,\"y\":143.6514,\"width\":331.54974,\"height\":414.43723,\"yaw\":-0.07131743,";
        faceMockup += "\"pitch\":-6.6307373,\"roll\":-2.5829313,\"quality\":9.658932,";
        faceMockup += "\"leftEye\":[101,322.5],\"rightEye\":[213,321],";
        faceMockup += "\"data\":\"TESTING_DATA\",";
        faceMockup += "\"faceTemplate\":{\"data\":\"FACE_TEMPLATE_TEST_DATA\",\"version\":1}}";
        
        return faceMockup;
    }
    //End Methods For Testing
}

public enum VerIDPluginError: Int, Error {
    case parsingError, invalidArgument, encodingError, faceTemplateExtractionError
}

class CodableSessionResult: Codable {
    
    enum CodingKeys: String, CodingKey {
        case attachments, error
    }
    
    enum AttachmentCodingKeys: String, CodingKey {
        case recognizableFace, bearing, image
    }
    
    let original: VerIDSessionResult
    
    init(_ result: VerIDSessionResult) {
        self.original = result
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let error = try container.decodeIfPresent(String.self, forKey: .error) {
            self.original = VerIDSessionResult(error: NSError(domain: kVerIDErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: error]))
        } else {
            var attachments: [DetectedFace] = []
            var attachmentsContainer = try container.nestedUnkeyedContainer(forKey: .attachments)
            while !attachmentsContainer.isAtEnd {
                let attachmentContainer = try attachmentsContainer.nestedContainer(keyedBy: AttachmentCodingKeys.self)
                let codableFace = try attachmentContainer.decode(CodableFace.self, forKey: .recognizableFace)
                let bearing = try attachmentContainer.decode(Bearing.self, forKey: .bearing)
                let imageURL: URL?
                if let imageString = try attachmentContainer.decodeIfPresent(String.self, forKey: .image) {
                    let pattern = "^data:(.+?);base64,(.+)$"
                    let regex = try NSRegularExpression(pattern: pattern, options: [])
                    let all = NSMakeRange(0, imageString.utf16.count)
                    guard let result = regex.firstMatch(in: imageString, options: [], range: all), result.numberOfRanges == 3 else {
                        throw DecodingError.dataCorruptedError(forKey: AttachmentCodingKeys.image, in: attachmentContainer, debugDescription: "Failed to parse image")
                    }
                    let data = (imageString as NSString).substring(with: result.range(at: 2))
                    guard let imageData = Data(base64Encoded: data) else {
                        throw DecodingError.dataCorruptedError(forKey: AttachmentCodingKeys.image, in: attachmentContainer, debugDescription: "Failed to decode image data")
                    }
                    imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
                    try imageData.write(to: imageURL!)
                } else {
                    imageURL = nil
                }
                let attachment = DetectedFace(face: codableFace.recognizableFace ?? codableFace.face, bearing: bearing, imageURL: imageURL)
                attachments.append(attachment)
            }
            self.original = VerIDSessionResult(attachments: attachments)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var attachmentsContainer = container.nestedUnkeyedContainer(forKey: .attachments)
        try self.original.attachments.forEach({
            var attachmentContainer = attachmentsContainer.nestedContainer(keyedBy: AttachmentCodingKeys.self)
            try attachmentContainer.encode(CodableFace(face: $0.face, recognizable: $0.face as? Recognizable), forKey: .recognizableFace)
            try attachmentContainer.encode($0.bearing, forKey: .bearing)
            if let imageURL = $0.imageURL, let data = try? Data(contentsOf: imageURL), let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8)?.base64EncodedString() {
                try attachmentContainer.encode(String(format: "data:image/jpeg;base64,%@", jpeg), forKey: .image)
            }
        })
        if let error = original.error {
            try container.encode(error.localizedDescription, forKey: .error)
        }
    }
}

class CodableFace: NSObject, Codable {
    
    enum CodingKeys: String, CodingKey {
        case data, faceTemplate, height, leftEye, pitch, quality, rightEye, roll, width, x, y, yaw
    }
    
    enum FaceTemplateCodingKeys: String, CodingKey {
        case data, version
    }
    
    let face: Face
    let recognizable: Recognizable?
    
    lazy var recognizableFace: RecognizableFace? = {
        guard let recognizable = self.recognizable else {
            return nil
        }
        return RecognizableFace(face: self.face, recognitionData: recognizable.recognitionData, version: recognizable.version)
    }()
    
    init(face: Face, recognizable: Recognizable?) {
        self.face = face
        self.recognizable = recognizable
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.face = Face()
        self.face.data = try container.decode(Data.self, forKey: .data)
        self.face.leftEye = try container.decode(CGPoint.self, forKey: .leftEye)
        self.face.rightEye = try container.decode(CGPoint.self, forKey: .rightEye)
        self.face.bounds = CGRect(x: try container.decode(CGFloat.self, forKey: .x), y: try container.decode(CGFloat.self, forKey: .y), width: try container.decode(CGFloat.self, forKey: .width), height: try container.decode(CGFloat.self, forKey: .height))
        self.face.angle = EulerAngle(yaw: try container.decode(CGFloat.self, forKey: .yaw), pitch: try container.decode(CGFloat.self, forKey: .pitch), roll: try container.decode(CGFloat.self, forKey: .roll))
        self.face.quality = try container.decode(CGFloat.self, forKey: .quality)
        if container.contains(.faceTemplate) {
            let faceTemplateContainer = try container.nestedContainer(keyedBy: FaceTemplateCodingKeys.self, forKey: .faceTemplate)
            self.recognizable = RecognitionFace(recognitionData: try faceTemplateContainer.decode(Data.self, forKey: .data))
            self.recognizable?.version = try faceTemplateContainer.decode(Int32.self, forKey: .version)
        } else {
            self.recognizable = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.face.data, forKey: .data)
        try container.encode(self.face.leftEye, forKey: .leftEye)
        try container.encode(self.face.rightEye, forKey: .rightEye)
        try container.encode(self.face.quality, forKey: .quality)
        try container.encode(self.face.bounds.minX, forKey: .x)
        try container.encode(self.face.bounds.minY, forKey: .y)
        try container.encode(self.face.bounds.width, forKey: .width)
        try container.encode(self.face.bounds.height, forKey: .height)
        try container.encode(self.face.angle.yaw, forKey: .yaw)
        try container.encode(self.face.angle.pitch, forKey: .pitch)
        try container.encode(self.face.angle.roll, forKey: .roll)
        if let recognizable = self.recognizable {
            var faceTemplateContainer = container.nestedContainer(keyedBy: FaceTemplateCodingKeys.self, forKey: .faceTemplate)
            try faceTemplateContainer.encode(recognizable.recognitionData, forKey: .data)
            try faceTemplateContainer.encode(recognizable.version, forKey: .version)
        }
    }
}
