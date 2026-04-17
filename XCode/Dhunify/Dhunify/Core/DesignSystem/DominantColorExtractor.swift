//
//  DominantColorExtractor.swift
//  Dhunify
//
//  Pulls a saturated representative color out of artwork so the player
//  and mini player can tint their backgrounds to the song.
//

import SwiftUI
import UIKit

@MainActor
enum DominantColorExtractor {
    static func extract(from urlString: String) async -> Color {
        guard let url = URL(string: urlString) else { return .appSurface }
        if let cached = ImageCache.shared.get(urlString),
           let dominant = cached.dominantColor() {
            return Color(dominant)
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let uiImage = UIImage(data: data) else {
            return .appSurface
        }
        ImageCache.shared.set(urlString, image: uiImage)
        return uiImage.dominantColor().map { Color($0) } ?? .appSurface
    }
}

extension UIImage {
    /// Averages mid-brightness pixels in a 40×40 downsample so near-black
    /// and near-white pixels don't dominate the result.
    func dominantColor() -> UIColor? {
        guard let cgImage = self.cgImage else { return nil }
        let width = 40
        let height = 40
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rawData,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var r = 0, g = 0, b = 0, count = 0
        for i in stride(from: 0, to: rawData.count, by: 4) {
            let rr = Int(rawData[i])
            let gg = Int(rawData[i + 1])
            let bb = Int(rawData[i + 2])
            let brightness = (rr + gg + bb) / 3
            if brightness > 30 && brightness < 220 {
                r += rr; g += gg; b += bb; count += 1
            }
        }
        guard count > 0 else { return nil }
        return UIColor(
            red: CGFloat(r / count) / 255,
            green: CGFloat(g / count) / 255,
            blue: CGFloat(b / count) / 255,
            alpha: 1
        )
    }
}
