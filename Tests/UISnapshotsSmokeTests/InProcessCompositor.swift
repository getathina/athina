#if UISnapshotsSmoke
  import AppKit
  import Metal
  import QuartzCore

  /// Core Animation's compositor run in the test process, over a window's content.
  ///
  /// Asking the views to draw instead, as `cacheDisplay` and `CALayer.render(in:)` do, draws what
  /// the window never shows and leaves out what it does. On macOS 27 they run a search field's
  /// cell, which draws the text that a label inside the field already shows, so the text comes out
  /// twice, and they apply no layer filters, which are what colour text on Liquid Glass, so it
  /// comes out black. The compositor takes the committed layers as they stand, filters included.
  @MainActor
  final class InProcessCompositor {
    /// Why no picture could be composited.
    enum Failure: Error {
      case noLayer
      case noMetal
      case noImage
    }

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let colorSpace: CGColorSpace
    /// The one renderer every picture is composited with, since a new one builds its Metal
    /// pipelines again, which took most of a second a picture on the runner.
    private var renderer: CARenderer?

    init() throws {
      guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
      else { throw Failure.noMetal }
      guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.noImage }
      self.device = device
      self.queue = queue
      self.colorSpace = colorSpace
    }

    /// The content view composited at one pixel a point, over the window's background colour.
    ///
    /// The content view rather than the frame view under it, whose layer tree composites empty
    /// until a later frame, and in a window taller than the display never composites at all.
    /// The content view's own layer is given the window's background for the picture, as glass
    /// and materials in it sample what is behind them.
    func picture(of content: NSView, in window: NSWindow) throws -> CGImage {
      guard let layer = content.layer else { throw Failure.noLayer }
      let width = Int(content.bounds.width)
      let height = Int(content.bounds.height)
      let shape = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width,
        height: height,
        mipmapped: false
      )
      shape.usage = [.renderTarget, .shaderRead]
      shape.storageMode = device.hasUnifiedMemory ? .shared : .managed
      guard let texture = device.makeTexture(descriptor: shape) else { throw Failure.noMetal }
      let renderer = renderer(into: texture)

      let background = layer.backgroundColor
      window.effectiveAppearance.performAsCurrentDrawingAppearance {
        setBackground(window.backgroundColor.cgColor, of: layer)
      }
      defer { setBackground(background, of: layer) }

      let bounds = CGRect(x: 0, y: 0, width: width, height: height)
      renderer.layer = layer
      defer { renderer.layer = nil }
      renderer.bounds = bounds
      CATransaction.flush()
      renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
      renderer.addUpdate(bounds)
      renderer.render()
      renderer.endFrame()

      // Given a queue, the renderer only commits to it, so a buffer after its own is waited for.
      guard let finished = queue.makeCommandBuffer() else { throw Failure.noMetal }
      if texture.storageMode == .managed, let blit = finished.makeBlitCommandEncoder() {
        blit.synchronize(resource: texture)
        blit.endEncoding()
      }
      finished.commit()
      finished.waitUntilCompleted()
      return try image(from: texture)
    }

    private func renderer(into texture: any MTLTexture) -> CARenderer {
      if let renderer {
        renderer.setDestination(texture)
        return renderer
      }
      let made = CARenderer(
        mtlTexture: texture,
        options: [kCARendererColorSpace: colorSpace, kCARendererMetalCommandQueue: queue]
      )
      renderer = made
      return made
    }

    private func setBackground(_ color: CGColor?, of layer: CALayer) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.backgroundColor = color
      CATransaction.commit()
    }

    /// The texture as an image, whose first row is the top one: the renderer's origin is the
    /// bottom left.
    private func image(from texture: any MTLTexture) throws -> CGImage {
      let rowBytes = texture.width * 4
      var bottomUp = [UInt8](repeating: 0, count: rowBytes * texture.height)
      texture.getBytes(
        &bottomUp,
        bytesPerRow: rowBytes,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
      )
      var topDown = Data(capacity: bottomUp.count)
      bottomUp.withUnsafeBufferPointer { bytes in
        for row in (0..<texture.height).reversed() {
          topDown.append(
            UnsafeBufferPointer(rebasing: bytes[(row * rowBytes)..<((row + 1) * rowBytes)])
          )
        }
      }
      let layout = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue
      )
      guard let provider = CGDataProvider(data: topDown as CFData),
        let image = CGImage(
          width: texture.width,
          height: texture.height,
          bitsPerComponent: 8,
          bitsPerPixel: 32,
          bytesPerRow: rowBytes,
          space: colorSpace,
          bitmapInfo: layout,
          provider: provider,
          decode: nil,
          shouldInterpolate: false,
          intent: .defaultIntent
        )
      else { throw Failure.noImage }
      return image
    }
  }
#endif
