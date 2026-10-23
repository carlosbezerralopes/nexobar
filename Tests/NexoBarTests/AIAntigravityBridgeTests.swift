import XCTest
import Darwin
@testable import NexoBar

final class AIAntigravityBridgeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_584_000)
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testDiscoveryRequiresAntigravityBundleAndNativeServer() throws {
        let good = try server(bundleID: "com.google.antigravity", name: "Valid")
        let wrong = try server(bundleID: "com.exafunction.windsurf", name: "Other")
        XCTAssertTrue(AIAntigravityBridge.trustedServer(good.path))
        XCTAssertFalse(AIAntigravityBridge.trustedServer(wrong.path))
        XCTAssertFalse(AIAntigravityBridge.trustedServer(good.deletingLastPathComponent().appendingPathComponent("unrelated").path))
        let valid = candidate(path: good.path)
        XCTAssertNotNil(AIAntigravityBridge.discover(candidates: [valid]))
        XCTAssertNil(AIAntigravityBridge.discover(candidates: [candidate(path: wrong.path)]))
    }
    func testDiscoveryRejectsRemotePortsAndMissingOrAmbiguousToken() throws {
        let path = try server(bundleID: "com.google.antigravity", name: "Valid").path
        var input = candidate(path: path)
        input.listeners = [.init(host:"192.168.0.10",port:1234,generation:1)]
        XCTAssertNil(AIAntigravityBridge.discover(candidates:[input]))
        input = candidate(path:path); input.arguments = [path]
        XCTAssertNil(AIAntigravityBridge.discover(candidates:[input]))
        input.arguments = [path,"--csrf_token","one","--csrf_token=two"]
        XCTAssertNil(AIAntigravityBridge.discover(candidates:[input]))
        XCTAssertNil(AIAntigravityBridge.csrfToken(arguments:[path,"--csrf_token","value\r\nheader"]))
    }
    func testArgvParserStopsBeforeEnvironment() {
        let path = "/fixture/language_server"
        let argv = arguments(path:path,values:[path,"--csrf_token","fixture-secret"],environment:["UNRELATED=private-fixture"])
        XCTAssertEqual(AIAntigravityBridge.parseArguments(argv),[path,"--csrf_token","fixture-secret"])
        let envOnly = arguments(path:path,values:[path],environment:["--csrf_token=environment-must-not-be-used"])
        XCTAssertNil(AIAntigravityBridge.parseArguments(envOnly).flatMap(AIAntigravityBridge.csrfToken))
        XCTAssertNil(AIAntigravityBridge.parseArguments(Data([255,255,255,127])))
    }
    func testRequestIsExactLoopbackServiceAndEndpointDescriptionRedactsToken() throws {
        let path = try server(bundleID:"com.google.antigravity",name:"Valid").path
        let endpoint = try XCTUnwrap(AIAntigravityBridge.discover(candidates:[candidate(path:path)]))
        let listener = try XCTUnwrap(endpoint.listeners.first)
        let request = try AIAntigravityBridge.makeRequest(endpoint:endpoint,listener:listener,timeout:3)
        XCTAssertEqual(request.url?.host,"127.0.0.1")
        XCTAssertEqual(request.url?.path,AIAntigravityBridge.service)
        XCTAssertEqual(request.httpMethod,"POST")
        XCTAssertEqual(request.value(forHTTPHeaderField:AIAntigravityBridge.csrfHeader),"fixture-secret")
        XCTAssertEqual(String(decoding:request.httpBody ?? Data(),as:UTF8.self),#"{"forceRefresh":true}"#)
        XCTAssertFalse(String(describing:endpoint).contains("fixture-secret"))
        XCTAssertFalse(String(reflecting:endpoint).contains("fixture-secret"))
    }
    func testURLAndTLSExceptionCannotReachRemoteOrAnotherLocalService() {
        let listener = AIAntigravityBridge.Listener(host:"127.0.0.1",port:4321,generation:1)
        for text in ["https://example.com:4321", "https://localhost:4321", "http://127.0.0.1:4321", "https://127.0.0.1:4322", "https://user:password@127.0.0.1:4321"] {
            XCTAssertFalse(AIAntigravityBridge.allowedURL(URL(string:text+AIAntigravityBridge.service)!,listener:listener))
        }
        XCTAssertFalse(AIAntigravityBridge.allowedURL(URL(string:"https://127.0.0.1:4321/another-service")!,listener:listener))
        XCTAssertTrue(AIAntigravityBridge.allowsTrust(host:"127.0.0.1",port:4321,method:NSURLAuthenticationMethodServerTrust,listener:listener,ownsSocket:true))
        XCTAssertFalse(AIAntigravityBridge.allowsTrust(host:"example.com",port:4321,method:NSURLAuthenticationMethodServerTrust,listener:listener,ownsSocket:true))
        XCTAssertFalse(AIAntigravityBridge.allowsTrust(host:"127.0.0.1",port:4321,method:NSURLAuthenticationMethodServerTrust,listener:listener,ownsSocket:false))
        XCTAssertFalse(AIAntigravityBridge.allowsTrust(host:"127.0.0.1",port:4322,method:NSURLAuthenticationMethodServerTrust,listener:listener,ownsSocket:true))
        XCTAssertFalse(AIAntigravityBridge.allowsTrust(host:"127.0.0.1",port:4321,method:NSURLAuthenticationMethodHTTPBasic,listener:listener,ownsSocket:true))
    }
    func testIPv6UsesNumericLoopbackOnly() throws {
        let path = try server(bundleID:"com.google.antigravity",name:"Valid").path
        var input = candidate(path:path); input.listeners = [.init(host:"::1",port:4321,generation:2)]
        let endpoint = try XCTUnwrap(AIAntigravityBridge.discover(candidates:[input]))
        let request = try AIAntigravityBridge.makeRequest(endpoint:endpoint,listener:endpoint.listeners[0],timeout:3)
        XCTAssertTrue(AIAntigravityBridge.allowedURL(try XCTUnwrap(request.url),listener:endpoint.listeners[0]))
        XCTAssertFalse(AIAntigravityBridge.isLoopback("::ffff:192.168.1.1"))
    }
    func testWrongServicePayloadTriesNextOwnedListenerAndInvertsRemainingOnce() throws {
        let path = try server(bundleID:"com.google.antigravity",name:"Valid").path
        var input = candidate(path:path); input.listeners.append(.init(host:"127.0.0.1",port:4322,generation:2))
        let endpoint = try XCTUnwrap(AIAntigravityBridge.discover(candidates:[input]))
        var called:[Int] = []
        let result = try AIAntigravityBridge.quota(from:endpoint,now:now,request:{ _,listener,timeout in
            called.append(listener.port); XCTAssertLessThanOrEqual(timeout,8)
            if listener.port == 4321 { return Data(#"{"status":"ok"}"#.utf8) }
            return Data(#"{"buckets":[{"modelId":"gemini-pro","remainingFraction":0.8,"resetTime":"2026-10-22T00:00:00Z"}]}"#.utf8)
        })
        XCTAssertEqual(called,[4321,4322])
        XCTAssertEqual(result.id,.antigravity)
        XCTAssertEqual(result.windows.count,1)
        XCTAssertEqual(try XCTUnwrap(result.windows[0].usedPercent),20,accuracy:0.00001)
        XCTAssertTrue(result.detail.contains("local"))
        XCTAssertThrowsError(try AIAntigravityBridge.quota(from:endpoint,now:now,request:{ _,_,_ in Data(#"{"status":"ok"}"#.utf8) }))
    }
    func testExpiredDeadlineDoesNotContactAnyService() throws {
        let path = try server(bundleID:"com.google.antigravity",name:"Valid").path
        let endpoint = try XCTUnwrap(AIAntigravityBridge.discover(candidates:[candidate(path:path)]))
        XCTAssertThrowsError(try AIAntigravityBridge.quota(from:endpoint,now:now,deadline:0,request:{ _,_,_ in XCTFail("Expired deadline must not send CSRF"); return Data() }))
        XCTAssertFalse(AIAntigravityBridge.stillOwns(endpoint,listener:endpoint.listeners[0]))
    }
    func testRedirectAndTLSDelegateSelectorsAreRegistered() throws {
        let path = try server(bundleID:"com.google.antigravity",name:"Valid").path
        let endpoint = try XCTUnwrap(AIAntigravityBridge.discover(candidates:[candidate(path:path)]))
        let receiver = AILocalQuotaRequest(endpoint:endpoint,listener:endpoint.listeners[0])
        XCTAssertTrue(receiver.responds(to:#selector(URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:))))
        XCTAssertTrue(receiver.responds(to:#selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))))
    }
    func testKernelPortLookupUsesOnlyOwningPIDAndLoopback() throws {
        let fd = socket(AF_INET,SOCK_STREAM,0)
        guard fd >= 0 else { throw XCTSkip("Local sockets unavailable") }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let bound = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd,1) == 0 else { throw XCTSkip("Loopback listening denied") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&size) } },0)
        let port = Int(UInt16(bigEndian:address.sin_port))
        let sockets = AIAntigravityBridge.listeningSockets(of:getpid())
        XCTAssertTrue(sockets.contains { $0.port == port && $0.host == "127.0.0.1" })
        XCTAssertTrue(AIAntigravityBridge.listeningSockets(of:-1).isEmpty)
        XCTAssertNotNil(AIAntigravityBridge.processIdentity(getpid()))
    }

    private func server(bundleID:String,name:String) throws -> URL {
        let app = root.appendingPathComponent(name+".app")
        let resources = app.appendingPathComponent("Contents/Resources/bin")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        let info:[String:Any] = ["CFBundleIdentifier":bundleID,"CFBundleExecutable":"Electron","CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
        let path = resources.appendingPathComponent("language_server_macos_arm")
        try Data().write(to:path); return path
    }
    private func candidate(path:String) -> AIAntigravityBridge.Candidate {
        .init(identity:.init(pid:42,startedAt:now,executable:path),arguments:[path,"--csrf_token","fixture-secret"],
              listeners:[.init(host:"127.0.0.1",port:4321,generation:1)])
    }
    private func arguments(path:String,values:[String],environment:[String]) -> Data {
        var argc = Int32(values.count)
        var data = withUnsafeBytes(of:&argc) { Data($0) }
        data.append(Data(path.utf8)); data.append(contentsOf:[0,0,0])
        for text in values+environment { data.append(Data(text.utf8)); data.append(0) }
        return data
    }
}
