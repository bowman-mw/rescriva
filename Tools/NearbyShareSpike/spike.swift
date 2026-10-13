import Foundation
import WebRTC

// Usage: spike <offer.json> <key.pem> <cert.pem>
let args = CommandLine.arguments
let offerJSON = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
let keyPEM = try! String(contentsOfFile: args[2], encoding: .utf8)
let certPEM = try! String(contentsOfFile: args[3], encoding: .utf8)
let U = "rsU1abcd", P = "rescrivaPasswordDerived00"

func log(_ s: String) { print("[\(String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100)))] \(s)"); fflush(stdout) }

RTCInitializeSSL(); RTCSetMinDebugLogLevel(.info)
let factory = RTCPeerConnectionFactory()

final class Peer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
	func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCSignalingState) { log("signaling \(s.rawValue)") }
	func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
	func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
	func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
	func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCIceConnectionState) { log("ice \(s.rawValue)") }
	func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCIceGatheringState) { log("gathering \(s.rawValue)") }
	func peerConnection(_ pc: RTCPeerConnection, didGenerate c: RTCIceCandidate) { log("local cand: \(c.sdp)") }
	func peerConnection(_ pc: RTCPeerConnection, didRemove c: [RTCIceCandidate]) {}
	func peerConnection(_ pc: RTCPeerConnection, didOpen dc: RTCDataChannel) { log("didOpen dc \(dc.label)") }
	func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCPeerConnectionState) { log("pc \(s.rawValue)") }
	func dataChannelDidChangeState(_ dc: RTCDataChannel) {
		log("dc state \(dc.readyState.rawValue)")
		if dc.readyState == .open {
			dc.sendData(RTCDataBuffer(data: Data("hello from native".utf8), isBinary: false))
		}
	}
	func dataChannel(_ dc: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
		log("msg: \(String(decoding: buffer.data, as: UTF8.self))")
	}
}

let peer = Peer()
let config = RTCConfiguration()
config.sdpSemantics = .unifiedPlan
config.iceServers = []
config.certificate = RTCCertificate(privateKey: keyPEM, certificate: certPEM)
config.continualGatheringPolicy = .gatherOnce
let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: peer) else { fatalError("no pc") }
let dcConfig = RTCDataChannelConfiguration()
dcConfig.isNegotiated = true
dcConfig.channelId = 0
let dc = pc.dataChannel(forLabel: "rescriva", configuration: dcConfig)!
dc.delegate = peer

let mid = offerJSON["mid"] as! String
var lines = ["v=0", "o=- 4611731400430051336 2 IN IP4 127.0.0.1", "s=-", "t=0 0", "a=group:BUNDLE \(mid)", "a=msid-semantic: WMS",
			 "m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "c=IN IP4 0.0.0.0"]
for c in offerJSON["cands"] as! [String] { lines.append("a=candidate:\(c)") }
lines += ["a=ice-ufrag:\(offerJSON["ufrag"] as! String)", "a=ice-pwd:\(offerJSON["pwd"] as! String)", "a=ice-options:trickle",
		  "a=fingerprint:sha-256 \(offerJSON["fp"] as! String)", "a=setup:actpass", "a=mid:\(mid)", "a=sctp-port:5000", "a=max-message-size:262144", ""]
let offerSDP = lines.joined(separator: "\r\n")

pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offerSDP)) { err in
	if let err { log("setRemote error \(err)"); return }
	log("remote offer set")
	pc.answer(for: constraints) { answer, err in
		guard let answer else { log("answer error \(String(describing: err))"); return }
		var sdp = answer.sdp
		sdp = sdp.replacingOccurrences(of: #"a=ice-ufrag:[^\r\n]+"#, with: "a=ice-ufrag:\(U)", options: .regularExpression)
		sdp = sdp.replacingOccurrences(of: #"a=ice-pwd:[^\r\n]+"#, with: "a=ice-pwd:\(P)", options: .regularExpression)
		log("answer setup: \(sdp.components(separatedBy: "\r\n").filter { $0.hasPrefix("a=setup") || $0.hasPrefix("a=fingerprint") })")
		pc.setLocalDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { err in
			if let err { log("setLocal (munged) error \(err)"); return }
			log("local munged answer set")
		}
	}
}
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { exit(0) }
dispatchMain()
