//
//  SystemVolumeSlider.swift
//  Dhunify
//
//  Wraps MPVolumeView to control system volume.
//  Hides the route button, shows only the slider.
//

import MediaPlayer
import SwiftUI

struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.setVolumeThumbImage(UIImage(), for: .normal)
        // Style the slider tint
        view.tintColor = UIColor(Color.appAccent)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
