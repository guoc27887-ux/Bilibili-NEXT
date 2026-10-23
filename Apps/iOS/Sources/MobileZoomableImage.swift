import SwiftUI
import UIKit

/// Use native zoom/pan physics so a magnified image can be inspected beyond its centre.
struct MobileZoomableImage: UIViewRepresentable {
  let image: UIImage
  func makeUIView(context: Context) -> ImageZoomView {
    let view = ImageZoomView()
    view.setImage(image)
    return view
  }
  func updateUIView(_ view: ImageZoomView, context: Context) { view.setImage(image) }
}

final class ImageZoomView: UIScrollView, UIScrollViewDelegate {
  private let picture = UIImageView()
  private var viewport = CGSize.zero
  override init(frame: CGRect) {
    super.init(frame: frame)
    delegate = self
    showsHorizontalScrollIndicator = false
    showsVerticalScrollIndicator = false
    contentInsetAdjustmentBehavior = .never
    bouncesZoom = true
    picture.contentMode = .scaleAspectFit
    addSubview(picture)
    let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
    tap.numberOfTapsRequired = 2
    addGestureRecognizer(tap)
    accessibilityIdentifier = "image-zoom-view"
    picture.isAccessibilityElement = true
    picture.accessibilityLabel = "图片，可双指缩放，放大后拖动查看"
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func setImage(_ image: UIImage) {
    guard picture.image !== image else { return }
    picture.image = image
    viewport = .zero
    setNeedsLayout()
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.size.width > 0, bounds.size.height > 0, let image = picture.image,
      image.size.width > 0, image.size.height > 0
    else { return }
    if viewport != bounds.size {
      viewport = bounds.size
      minimumZoomScale = 0.001
      maximumZoomScale = 100
      zoomScale = 1
      picture.frame = CGRect(origin: .zero, size: image.size)
      contentSize = image.size
      let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
      minimumZoomScale = fit
      maximumZoomScale = fit * 6
      zoomScale = fit
    }
    centerImage()
  }
  func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
  func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
  private func centerImage() {
    let x = max(0, (bounds.width - contentSize.width) / 2)
    let y = max(0, (bounds.height - contentSize.height) / 2)
    let insets = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    if contentInset != insets { contentInset = insets }
    accessibilityValue = zoomScale > minimumZoomScale * 1.01 ? "已放大" : "适应屏幕"
  }
  @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
    if zoomScale > minimumZoomScale * 1.01 {
      setZoomScale(minimumZoomScale, animated: true)
    } else {
      let scale = min(maximumZoomScale, minimumZoomScale * 2.5)
      let point = gesture.location(in: picture)
      let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
      zoom(
        to: CGRect(
          x: point.x - size.width / 2, y: point.y - size.height / 2,
          width: size.width, height: size.height), animated: true)
    }
  }
}
