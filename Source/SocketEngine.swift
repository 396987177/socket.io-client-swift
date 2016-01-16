//
//  SocketEngine.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 3/3/15.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation

public final class SocketEngine: NSObject, SocketEnginePollable, SocketEngineWebsocket {
    public let emitQueue = dispatch_queue_create("com.socketio.engineEmitQueue", DISPATCH_QUEUE_SERIAL)
    public let handleQueue = dispatch_queue_create("com.socketio.engineHandleQueue", DISPATCH_QUEUE_SERIAL)
    public let parseQueue = dispatch_queue_create("com.socketio.engineParseQueue", DISPATCH_QUEUE_SERIAL)

    public var postWait = [String]()
    public var waitingForPoll = false
    public var waitingForPost = false
    
    public private(set) var closed = false
    public private(set) var connected = false
    public private(set) var cookies: [NSHTTPCookie]?
    public private(set) var extraHeaders: [String: String]?
    public private(set) var fastUpgrade = false
    public private(set) var forcePolling = false
    public private(set) var forceWebsockets = false
    public private(set) var invalidated = false
    public private(set) var pingTimer: NSTimer?
    public private(set) var polling = true
    public private(set) var probing = false
    public private(set) var session: NSURLSession?
    public private(set) var sid = ""
    public private(set) var socketPath = "/engine.io"
    public private(set) var urlPolling = ""
    public private(set) var urlWebSocket = ""
    public private(set) var websocket = false
    public private(set) var ws: WebSocket?

    public weak var client: SocketEngineClient?
    
    private weak var sessionDelegate: NSURLSessionDelegate?

    private typealias Probe = (msg: String, type: SocketEnginePacketType, data: [NSData])
    private typealias ProbeWaitQueue = [Probe]

    private let allowedCharacterSet = NSCharacterSet(charactersInString: "!*'();:@&=+$,/?%#[]\" {}").invertedSet
    private let logType = "SocketEngine"
    private let url: String
    
    private var connectParams: [String: AnyObject]?
    private var pingInterval: Double?
    private var pingTimeout = 0.0 {
        didSet {
            pongsMissedMax = Int(pingTimeout / (pingInterval ?? 25))
        }
    }
    private var pongsMissed = 0
    private var pongsMissedMax = 0
    private var probeWait = ProbeWaitQueue()
    private var secure = false
    private var selfSigned = false
    private var voipEnabled = false
    
    public init(client: SocketEngineClient, url: String, options: Set<SocketIOClientOption>) {
        self.client = client
        self.url = url

        for option in options {
            switch option {
            case let .SessionDelegate(delegate):
                sessionDelegate = delegate
            case let .ForcePolling(force):
                forcePolling = force
            case let .ForceWebsockets(force):
                forceWebsockets = force
            case let .Cookies(cookies):
                self.cookies = cookies
            case let .Path(path):
                socketPath = path
            case let .ExtraHeaders(headers):
                extraHeaders = headers
            case let .VoipEnabled(enable):
                voipEnabled = enable
            case let .Secure(secure):
                self.secure = secure
            case let .SelfSigned(selfSigned):
                self.selfSigned = selfSigned
            default:
                continue
            }
        }
    }
    
    public convenience init(client: SocketEngineClient, url: String, options: NSDictionary?) {
        self.init(client: client, url: url,
            options: options?.toSocketOptionsSet() ?? [])
    }

    deinit {
        DefaultSocketLogger.Logger.log("Engine is being deinit", type: logType)
        closed = true
        stopPolling()
    }
    
    private func checkAndHandleEngineError(msg: String) {
        guard let stringData = msg.dataUsingEncoding(NSUTF8StringEncoding,
            allowLossyConversion: false) else { return }
        
        do {
            if let dict = try NSJSONSerialization.JSONObjectWithData(stringData,
                options: NSJSONReadingOptions.MutableContainers) as? NSDictionary {
                    guard let code = dict["code"] as? Int else { return }
                    guard let error = dict["message"] as? String else { return }
                    
                    switch code {
                    case 0: // Unknown transport
                        didError(error)
                    case 1: // Unknown sid. clear and retry connect
                        sid = ""
                        open(connectParams)
                    case 2: // Bad handshake request
                        didError(error)
                    case 3: // Bad request
                        didError(error)
                    default:
                        didError(error)
                    }
            }
        } catch {
            didError("Got unknown error from server \(msg)")
        }
    }

    private func checkIfMessageIsBase64Binary(message: String) -> Bool {
        if message.hasPrefix("b4") {
            // binary in base64 string
            let noPrefix = message[message.startIndex.advancedBy(2)..<message.endIndex]

            if let data = NSData(base64EncodedString: noPrefix,
                options: .IgnoreUnknownCharacters) {
                    client?.parseEngineBinaryData(data)
            }
            
            return true
        } else {
            return false
        }
    }

    public func close() {
        DefaultSocketLogger.Logger.log("Engine is being closed.", type: logType)

        pingTimer?.invalidate()
        closed = true
        invalidated = true
        connected = false

        if websocket {
            sendWebSocketMessage("", withType: .Close, withData: [])
        } else {
            sendPollMessage("", withType: .Close, withData: [])
        }
        
        ws?.disconnect()
        stopPolling()
        client?.engineDidClose("Disconnect")
    }

    private func createURLs(params: [String: AnyObject]?) -> (String, String) {
        if client == nil {
            return ("", "")
        }

        let socketURL = "\(url)\(socketPath)/?transport="
        var urlPolling: String
        var urlWebSocket: String

        if secure {
            urlPolling = "https://" + socketURL + "polling"
            urlWebSocket = "wss://" + socketURL + "websocket"
        } else {
            urlPolling = "http://" + socketURL + "polling"
            urlWebSocket = "ws://" + socketURL + "websocket"
        }

        if params != nil {
            for (key, value) in params! {
                let keyEsc = key.stringByAddingPercentEncodingWithAllowedCharacters(
                    allowedCharacterSet)!
                urlPolling += "&\(keyEsc)="
                urlWebSocket += "&\(keyEsc)="

                if value is String {
                    let valueEsc = (value as! String).stringByAddingPercentEncodingWithAllowedCharacters(
                        allowedCharacterSet)!
                    urlPolling += "\(valueEsc)"
                    urlWebSocket += "\(valueEsc)"
                } else {
                    urlPolling += "\(value)"
                    urlWebSocket += "\(value)"
                }
            }
        }

        return (urlPolling, urlWebSocket)
    }

    private func createWebsocketAndConnect(connect: Bool) {
        let wsUrl = urlWebSocket + (sid == "" ? "" : "&sid=\(sid)")

        ws = WebSocket(url: NSURL(string: wsUrl)!)
        
        if cookies != nil {
            let headers = NSHTTPCookie.requestHeaderFieldsWithCookies(cookies!)
            for (key, value) in headers {
                ws?.headers[key] = value
            }
        }

        if extraHeaders != nil {
            for (headerName, value) in extraHeaders! {
                ws?.headers[headerName] = value
            }
        }

        ws?.queue = handleQueue
        ws?.voipEnabled = voipEnabled
        ws?.delegate = self
        ws?.selfSignedSSL = selfSigned

        if connect {
            ws?.connect()
        }
    }
    
    public func didError(error: String) {
        connected = false
        ws?.disconnect()
        stopPolling()
        pingTimer?.invalidate()
        
        DefaultSocketLogger.Logger.error(error, type: logType)
        client?.engineDidError(error)
        client?.engineDidClose(error)
    }

    public func doFastUpgrade() {
        if waitingForPoll {
            DefaultSocketLogger.Logger.error("Outstanding poll when switched to WebSockets," +
                "we'll probably disconnect soon. You should report this.", type: logType)
        }

        sendWebSocketMessage("", withType: .Upgrade, withData: [])
        websocket = true
        polling = false
        fastUpgrade = false
        probing = false
        flushProbeWait()
    }

    private func flushProbeWait() {
        DefaultSocketLogger.Logger.log("Flushing probe wait", type: logType)

        dispatch_async(emitQueue) {
            for waiter in self.probeWait {
                self.write(waiter.msg, withType: waiter.type, withData: waiter.data)
            }
            
            self.probeWait.removeAll(keepCapacity: false)
            
            if self.postWait.count != 0 {
                self.flushWaitingForPostToWebSocket()
            }
        }
    }
    
    // We had packets waiting for send when we upgraded
    // Send them raw
    public func flushWaitingForPostToWebSocket() {
        guard let ws = self.ws else { return }
        
        for msg in postWait {
            ws.writeString(fixDoubleUTF8(msg))
        }
        
        postWait.removeAll(keepCapacity: true)
    }

    private func handleClose(reason: String) {
        client?.engineDidClose(reason)
    }

    private func handleMessage(message: String) {
        client?.parseEngineMessage(message)
    }

    private func handleNOOP() {
        doPoll()
    }

    private func handleOpen(openData: String) {
        let mesData = openData.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)!
        do {
            let json = try NSJSONSerialization.JSONObjectWithData(mesData,
                options: NSJSONReadingOptions.AllowFragments) as? NSDictionary
            if let sid = json?["sid"] as? String {
                let upgradeWs: Bool

                self.sid = sid
                connected = true

                if let upgrades = json?["upgrades"] as? [String] {
                    upgradeWs = upgrades.contains("websocket")
                } else {
                    upgradeWs = false
                }

                if let pingInterval = json?["pingInterval"] as? Double, pingTimeout = json?["pingTimeout"] as? Double {
                    self.pingInterval = pingInterval / 1000.0
                    self.pingTimeout = pingTimeout / 1000.0
                }

                if !forcePolling && !forceWebsockets && upgradeWs {
                    createWebsocketAndConnect(true)
                }
                
                
                startPingTimer()
                
                if !forceWebsockets {
                    doPoll()
                }
                
                client?.engineDidOpen?("Connect")
            }
        } catch {
            didError("Error parsing open packet")
            return
        }
    }

    private func handlePong(pongMessage: String) {
        pongsMissed = 0

        // We should upgrade
        if pongMessage == "3probe" {
            upgradeTransport()
        }
    }

    public func open(opts: [String: AnyObject]? = nil) {
        connectParams = opts
        
        if connected {
            DefaultSocketLogger.Logger.error("Tried to open while connected", type: logType)
            didError("Tried to open engine while connected")

            return
        }

        DefaultSocketLogger.Logger.log("Starting engine", type: logType)
        DefaultSocketLogger.Logger.log("Handshaking", type: logType)

        resetEngine()

        (urlPolling, urlWebSocket) = createURLs(opts)

        if forceWebsockets {
            polling = false
            websocket = true
            createWebsocketAndConnect(true)
            return
        }

        let reqPolling = NSMutableURLRequest(URL: NSURL(string: urlPolling + "&b64=1")!)

        if cookies != nil {
            let headers = NSHTTPCookie.requestHeaderFieldsWithCookies(cookies!)
            reqPolling.allHTTPHeaderFields = headers
        }

        if let extraHeaders = extraHeaders {
            for (headerName, value) in extraHeaders {
                reqPolling.setValue(value, forHTTPHeaderField: headerName)
            }
        }

        doLongPoll(reqPolling)
    }

    public func parseEngineData(data: NSData) {
        DefaultSocketLogger.Logger.log("Got binary data: %@", type: "SocketEngine", args: data)
        client?.parseEngineBinaryData(data.subdataWithRange(NSMakeRange(1, data.length - 1)))
    }

    public func parseEngineMessage(message: String, fromPolling: Bool) {
        DefaultSocketLogger.Logger.log("Got message: %@", type: logType, args: message)
        
        let reader = SocketStringReader(message: message)
        let fixedString: String

        guard let type = SocketEnginePacketType(rawValue: Int(reader.currentCharacter) ?? -1) else {
            if !checkIfMessageIsBase64Binary(message) {
                checkAndHandleEngineError(message)
            }
            
            return
        }

        if fromPolling && type != .Noop {
            fixedString = fixDoubleUTF8(message)
        } else {
            fixedString = message
        }

        switch type {
        case .Message:
            handleMessage(fixedString[fixedString.startIndex.successor()..<fixedString.endIndex])
        case .Noop:
            handleNOOP()
        case .Pong:
            handlePong(fixedString)
        case .Open:
            handleOpen(fixedString[fixedString.startIndex.successor()..<fixedString.endIndex])
        case .Close:
            handleClose(fixedString)
        default:
            DefaultSocketLogger.Logger.log("Got unknown packet type", type: logType)
        }
    }
    
    private func resetEngine() {
        closed = false
        connected = false
        fastUpgrade = false
        polling = true
        probing = false
        invalidated = false
        session = NSURLSession(configuration: .defaultSessionConfiguration(),
            delegate: sessionDelegate,
            delegateQueue: NSOperationQueue())
        sid = ""
        waitingForPoll = false
        waitingForPost = false
        websocket = false
    }
    
    /// Send an engine message (4)
    public func send(msg: String, withData datas: [NSData]) {
        if probing {
            probeWait.append((msg, .Message, datas))
        } else {
            write(msg, withType: .Message, withData: datas)
        }
    }

    @objc private func sendPing() {
        //Server is not responding
        if pongsMissed > pongsMissedMax {
            pingTimer?.invalidate()
            client?.engineDidClose("Ping timeout")
            return
        }

        pongsMissed += 1
        write("", withType: .Ping, withData: [])
    }

    // Starts the ping timer
    private func startPingTimer() {
        if let pingInterval = pingInterval {
            pingTimer?.invalidate()
            pingTimer = nil

            dispatch_async(dispatch_get_main_queue()) {
                self.pingTimer = NSTimer.scheduledTimerWithTimeInterval(pingInterval, target: self,
                    selector: Selector("sendPing"), userInfo: nil, repeats: true)
            }
        }
    }

    private func upgradeTransport() {
        if ws?.isConnected ?? false {
            DefaultSocketLogger.Logger.log("Upgrading transport to WebSockets", type: logType)

            fastUpgrade = true
            sendPollMessage("", withType: .Noop, withData: [])
            // After this point, we should not send anymore polling messages
        }
    }

    /**
    Write a message, independent of transport.
     */
    public func write(msg: String, withType type: SocketEnginePacketType, withData data: [NSData]) {
        dispatch_async(emitQueue) {
            guard self.connected else { return }
            
            if self.websocket {
                DefaultSocketLogger.Logger.log("Writing ws: %@ has data: %@",
                    type: self.logType, args: msg, data.count != 0)
                self.sendWebSocketMessage(msg, withType: type, withData: data)
            } else {
                DefaultSocketLogger.Logger.log("Writing poll: %@ has data: %@",
                    type: self.logType, args: msg, data.count != 0)
                self.sendPollMessage(msg, withType: type, withData: data)
            }
        }
    }
    
    // Delegate methods
    public func websocketDidConnect(socket: WebSocket) {
        if !forceWebsockets {
            probing = true
            probeWebSocket()
        } else {
            connected = true
            probing = false
            polling = false
        }
    }
    
    public func websocketDidDisconnect(socket: WebSocket, error: NSError?) {
        probing = false
        
        if closed {
            client?.engineDidClose("Disconnect")
            return
        }
        
        if websocket {
            pingTimer?.invalidate()
            connected = false
            websocket = false
            
            let reason = error?.localizedDescription ?? "Socket Disconnected"
            
            if error != nil {
                didError(reason)
            }
            
            client?.engineDidClose(reason)
        } else {
            flushProbeWait()
        }
    }
}