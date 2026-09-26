import CoreImage

/// Centre-crops a developed (upright) image to a `FrameRatio`. The crop
/// follows the image's own orientation: a landscape shot at 16:9 comes out
/// 16:9 wide, a portrait one 9:16 tall.
enum RatioCrop {
    static func crop(_ image: CIImage, to ratio: FrameRatio) -> CIImage {
        let extent = image.extent
        // CGRect.infinite has a huge-but-finite width, so check isInfinite explicitly.
        guard ratio != .fourThree, !extent.isInfinite, !extent.isEmpty,
              extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite else { return image }

        let landscape = extent.width >= extent.height
        let target = CGFloat(landscape ? ratio.longOverShort : ratio.portraitAspect)   // width / height
        var width = extent.width
        var height = extent.height
        if width / height > target {
            width = (height * target).rounded(.down)
        } else {
            height = (width / target).rounded(.down)
        }
        let rect = CGRect(
            x: (extent.midX - width / 2).rounded(),
            y: (extent.midY - height / 2).rounded(),
            width: width,
            height: height
        )
        return image
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }
}
