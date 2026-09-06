#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/remodex-pairing-qr.XXXXXX")"
printf 'import AppKit\nimport CoreImage\nimport CoreImage.CIFilterBuiltins\nimport Vision\n' > "$work/QRProbe.swift"
sed -n '/^@MainActor$/,$p' "$root/CodexMobile/RemodexMenuBar/BridgeMenuBarViews.swift" | sed -n '/^private enum PairingQRImageCache/,$p' >> "$work/QRProbe.swift"
cat >> "$work/QRProbe.swift" <<'SWIFT'
@main struct QRProbe {
    @MainActor static func main() throws {
        let hosts = ["wss://fixture.invalid", "wss://" + Array(repeating: String(repeating: "a", count: 60), count: 4).joined(separator: ".")]
        var checks = 0
        for host in hosts {
            let fields = [host, String(repeating: "A", count: 43), Data(repeating: 7, count: 32).base64EncodedString()]
            let text = "RDX2:" + String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
            guard let image = PairingQRImageCache.image(text: text), let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("qr_generation_failed") }
            for size in [300, 600] {
                guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("bitmap_failed") }
                context.interpolationQuality = .none
                context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
                guard let bitmap = context.makeImage() else { fatalError("bitmap_failed") }
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                try VNImageRequestHandler(cgImage: bitmap).perform([request])
                guard request.results?.contains(where: { $0.payloadStringValue == text }) == true else { fatalError("rendered_qr_decode_failed") }
                checks += 1
            }
        }
        print("production_mac_qr_decode_passed checks=\(checks)")
    }
}
SWIFT
swiftc -swift-version 5 -parse-as-library -framework AppKit -framework CoreImage -framework Vision "$work/QRProbe.swift" -o "$work/qr-probe"
"$work/qr-probe"
printf 'evidence=%s\n' "$work"
