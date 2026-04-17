//
//  ShareCardGenerator.swift
//  Dhunify
//
//  Generates a shareable image card from a Song.
//  Artwork + title + artist + Dhunify branding.
//

import SwiftUI
import UIKit

@MainActor
struct ShareCardGenerator {

    /// Generate a share card image and present the share sheet.
    static func share(song: Song) {
        Task {
            let image = await generateCard(for: song)
            let text = "\(song.title) — \(song.artist)\n🎵 Playing on Dhunify"
            let items: [Any] = [image, text]

            let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.windows.first?.rootViewController {
                root.present(av, animated: true)
            }
        }
    }

    /// Renders a 600x800 card with artwork, song info, and branding.
    static func generateCard(for song: Song) async -> UIImage {
        let cardW: CGFloat = 600
        let cardH: CGFloat = 800

        // Try to download artwork.
        var artworkImage: UIImage?
        if let cached = ImageCache.shared.get(song.thumbnailURL) {
            artworkImage = cached
        } else if let url = URL(string: song.thumbnailURL) {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let img = UIImage(data: data) {
                artworkImage = img
            }
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: cardW, height: cardH))

        return renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: cardW, height: cardH)

            // Background gradient
            let colors = [
                UIColor(red: 108/255, green: 92/255, blue: 231/255, alpha: 1).cgColor,
                UIColor(red: 10/255, green: 10/255, blue: 10/255, alpha: 1).cgColor,
            ]
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 0.6]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: cardH), options: [])
            }

            // Artwork (centered, 400x400, rounded)
            let artSize: CGFloat = 400
            let artRect = CGRect(x: (cardW - artSize) / 2, y: 80, width: artSize, height: artSize)
            if let art = artworkImage {
                let path = UIBezierPath(roundedRect: artRect, cornerRadius: 24)
                ctx.cgContext.saveGState()
                path.addClip()
                art.draw(in: artRect)
                ctx.cgContext.restoreGState()
            } else {
                UIColor(red: 26/255, green: 26/255, blue: 26/255, alpha: 1).setFill()
                UIBezierPath(roundedRect: artRect, cornerRadius: 24).fill()
            }

            // Song title
            let titleFont = UIFont.systemFont(ofSize: 32, weight: .bold)
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: UIColor.white,
            ]
            let titleStr = song.title as NSString
            let titleSize = titleStr.size(withAttributes: titleAttrs)
            let titleX = (cardW - min(titleSize.width, cardW - 60)) / 2
            titleStr.draw(
                in: CGRect(x: titleX, y: 510, width: cardW - 60, height: 44),
                withAttributes: titleAttrs
            )

            // Artist
            let artistFont = UIFont.systemFont(ofSize: 22, weight: .medium)
            let artistAttrs: [NSAttributedString.Key: Any] = [
                .font: artistFont,
                .foregroundColor: UIColor(white: 0.7, alpha: 1),
            ]
            let artistStr = song.artist as NSString
            let artistSize = artistStr.size(withAttributes: artistAttrs)
            let artistX = (cardW - min(artistSize.width, cardW - 60)) / 2
            artistStr.draw(
                in: CGRect(x: artistX, y: 560, width: cardW - 60, height: 30),
                withAttributes: artistAttrs
            )

            // Dhunify branding
            let brandFont = UIFont.systemFont(ofSize: 18, weight: .bold)
            let brandAttrs: [NSAttributedString.Key: Any] = [
                .font: brandFont,
                .foregroundColor: UIColor(red: 108/255, green: 92/255, blue: 231/255, alpha: 0.9),
                .kern: 3.0,
            ]
            let brandStr = "DHUNIFY" as NSString
            let brandSize = brandStr.size(withAttributes: brandAttrs)
            brandStr.draw(
                at: CGPoint(x: (cardW - brandSize.width) / 2, y: cardH - 60),
                withAttributes: brandAttrs
            )
        }
    }
}
