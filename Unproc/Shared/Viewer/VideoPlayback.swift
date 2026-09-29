import AVFoundation
import Combine
import SwiftUI
import UIKit
import os

/// Plays a video item on top of its poster in the viewer: tap to play or
/// pause, rewinds at the end, pauses when paged away.
struct VideoPageOverlay: View {
    let store: any PhotoStore
    let item: PhotoItem
    let isCurrent: Bool

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isLoading = false
    @State private var playTick = 0

    var body: some View {
        ZStack {
            if let player {
                PlayerLayerView(player: player)
                    .allowsHitTesting(false)
            }
            if !isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .opacity(isLoading ? 0.5 : 1)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .animation(ViewerStyle.ui, value: isPlaying)
        .sensoryFeedback(.impact(weight: .light), trigger: playTick)
        .accessibilityElement()
        .accessibilityLabel(Text(isPlaying ? "Pause video" : "Play video"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("viewer.video")
        .onChange(of: isCurrent) { _, current in
            if !current { pause() }
        }
        .onDisappear { pause() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let player, let ended = note.object as? AVPlayerItem, ended === player.currentItem else { return }
            player.seek(to: .zero)
            isPlaying = false
        }
    }

    private func toggle() {
        playTick += 1
        if isPlaying {
            pause()
            return
        }
        if let player {
            player.play()
            isPlaying = true
            Log.viewer.info("viewer: play \(item.id, privacy: .public)")
            return
        }
        guard !isLoading else { return }
        isLoading = true
        Task {
            let asset = await store.videoAsset(for: item)
            isLoading = false
            guard let asset else {
                Log.viewer.error("viewer: no playable video for \(item.id, privacy: .public)")
                return
            }
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            newPlayer.actionAtItemEnd = .pause
            player = newPlayer
            guard isCurrent else { return }
            newPlayer.play()
            isPlaying = true
            Log.viewer.info("viewer: play \(item.id, privacy: .public) (loaded)")
        }
    }

    private func pause() {
        guard isPlaying else { return }
        player?.pause()
        isPlaying = false
    }
}

/// An `AVPlayerLayer` (aspect fit, like the poster under it).
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.playerLayer?.videoGravity = .resizeAspect
        view.playerLayer?.player = player
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        if uiView.playerLayer?.player !== player {
            uiView.playerLayer?.player = player
        }
    }
}

/// Small duration tag for video thumbnails ("0:05"), or a play glyph when
/// the duration is unknown.
struct VideoDurationBadge: View {
    let duration: Double
    var fontSize: CGFloat = 8

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "play.fill")
                .font(.system(size: fontSize - 1, weight: .bold))
            if duration > 0 {
                Text(Timecode.short(duration))
                    .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 3)
        .padding(.vertical, 1.5)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityLabel(Text("Video"))
    }
}
