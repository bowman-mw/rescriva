//
//  ShareCertificate.swift
//  Rescriva (fork of Open Scanner)
//
//  The DTLS certificate built into the app for no-relay pairing (ShareSite/PROTOCOL.md §3). The
//  page's made-up answer names its fingerprint before the app has said anything, so every copy of
//  the app uses this one. It's public on purpose: it doesn't prove the app is genuine, the hello
//  proof does. The website's APP_FINGERPRINT (ShareSite/assets/config.js) and PROTOCOL.md use the
//  same fingerprint; replace all three together. Made by Tools/NearbyShareSpike (P-256, PKCS#8).
//

import Foundation

enum ShareCertificate {
	/// The private key, PKCS#8 PEM.
	static let privateKeyPEM = """
		-----BEGIN PRIVATE KEY-----
		MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgyoM0+Y08UQ5XfyJH
		hPIgxowL28Q3YFdF89zm8Wf5qGWhRANCAAQRPiYBtuAG+30iruxlaDtuWKh1O1E4
		EEL1xPczinSC+svusxy5F5O9zntDPCgXLfh5LLnEixau666BR3keMhec
		-----END PRIVATE KEY-----

		"""

	/// The self-signed certificate ("Rescriva Share"), PEM.
	static let certificatePEM = """
		-----BEGIN CERTIFICATE-----
		MIIBIjCBygIJAMMEa1c8jL5xMAoGCCqGSM49BAMCMBkxFzAVBgNVBAMMDlJlc2Ny
		aXZhIFNoYXJlMCAXDTI2MTAxMjE0MTQxOVoYDzIxMjYwOTE4MTQxNDE5WjAZMRcw
		FQYDVQQDDA5SZXNjcml2YSBTaGFyZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IA
		BBE+JgG24Ab7fSKu7GVoO25YqHU7UTgQQvXE9zOKdIL6y+6zHLkXk73Oe0M8KBct
		+HksucSLFq7rroFHeR4yF5wwCgYIKoZIzj0EAwIDRwAwRAIgMq3dBq/9zM5v6ITe
		jk0LyQiBw5qBuIwPGwC2ERS+l9YCIArzR10lIAdHvezRC14awtWq5tft0JBl4agi
		yL6x1ut5
		-----END CERTIFICATE-----

		"""

	/// SHA-256 of the certificate's DER bytes, as SDP writes it.
	static let fingerprint = "C8:7F:82:09:B8:EF:F6:FB:92:37:13:91:BD:28:85:F1:50:E7:03:8D:3E:BB:DA:99:2A:78:3C:9F:DB:E1:95:CB"
}
