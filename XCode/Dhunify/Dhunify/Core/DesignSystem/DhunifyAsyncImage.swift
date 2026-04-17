//
//  DhunifyAsyncImage.swift
//  Dhunify
//
//  Cached image view. Uses an NSCache singleton so album artwork
//  is never re-downloaded during a session. Max 100 images in memory.
//

import SwiftUI
import UIKit

// MARK: - Image cache

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    func get(_ url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    func set(_ url: String, image: UIImage) {
        cache.setObject(image, forKey: url as NSString)
    }
}

// MARK: - Average color extraction

extension UIImage {
    /// Extracts the average color by downscaling to 1x1 pixel.
    var averageColor: Color {
        guard let cgImage else { return .appBackground }
        let size = CGSize(width: 1, height: 1)
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return .appBackground }
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let pixel = ctx.makeImage()?.dataProvider?.data,
              CFDataGetLength(pixel) >= 4 else { return .appBackground }
        let ptr = CFDataGetBytePtr(pixel)!
        let r = Double(ptr[0]) / 255
        let g = Double(ptr[1]) / 255
        let b = Double(ptr[2]) / 255
        // Darken slightly for better contrast with white text.
        return Color(red: r * 0.6, green: g * 0.6, blue: b * 0.6)
    }
}

// MARK: - View

struct DhunifyAsyncImage: View {
    let url: String
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 10

    @State private var image: UIImage? = nil
    @State private var failed = false
    @State private var blurAmount: CGFloat = 20

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: blurAmount)
                    .transition(.opacity)
                    .onAppear {
                        blurAmount = 20
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            blurAmount = 0
                        }
                    }
            } else if failed {
                ZStack {
                    Color.appSecondary.opacity(0.15)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.28))
                        .foregroundStyle(.appSecondary.opacity(0.6))
                }
            } else {
                Color.appSurface
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: image != nil)
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard !url.isEmpty else { failed = true; return }

        // Check cache.
        if let cached = ImageCache.shared.get(url) {
            image = cached
            return
        }

        // Download.
        guard let imageURL = URL(string: url) else { failed = true; return }
        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            if let uiImage = UIImage(data: data) {
                ImageCache.shared.set(url, image: uiImage)
                image = uiImage
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}
