#import "VlcTextureRenderer.h"

#if TARGET_OS_OSX
#import <VLCKit/VLCKit.h>
#else
#import <MobileVLCKit/MobileVLCKit.h>
#endif

#include <cstring>
#include <memory>
#include <mutex>

#include "vlc_frame_sink.h"
#include "vlc_video_output.h"

/// VLCKit and MobileVLCKit both publish the underlying libvlc handle through
/// a category in their private VLCLibVLCBridging.h. Re-declaring the one
/// property we need keeps that header out of our search path, at the cost of
/// depending on a private API - acceptable only because both podspecs pin the
/// framework to an exact version.
@interface VLCMediaPlayer (VlcPlayerLibVLCBridging)
@property(readonly) void *libVLCMediaPlayer;
@end

namespace {

/// NV12, not RGBA.
///
/// VideoToolbox already decodes to bi-planar NV12, so asking libVLC for it
/// deletes the swscale conversion to RGBA, moves 1.5 bytes per pixel instead
/// of 4, and lands in the one YUV layout Flutter's Metal external texture
/// samples directly on Darwin. Subtitles still work: libVLC 3 blends
/// subpictures in the *source* chroma inside the vout, before the converter
/// that produces our chroma runs.
///
/// FlutterTexture.h on both iOS and macOS names the formats copyPixelBuffer
/// may return: 32BGRA and the two NV12 variants. Swapping the three constants
/// below to kCVPixelFormatType_32BGRA / "BGRA" / 1 plane is the whole fallback
/// if NV12 ever misbehaves.
constexpr OSType kPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
constexpr char kChroma[] = "NV12";
constexpr uint32_t kPlaneCount = 2;

/// Bounds the pool so a stalled consumer cannot grow it without limit. One
/// buffer is being written, one is published, and the engine may hold one or
/// two more while it uploads.
constexpr int kPoolAllocationThreshold = 5;

/// Fills CVPixelBuffers out of a pool and publishes the newest complete one.
///
/// libVLC writes directly into pool memory, so there is no copy of our own
/// anywhere on this path.
class CVPixelBufferSink final : public vlc_player::VlcFrameSink {
 public:
  explicit CVPixelBufferSink(void (^on_frame_available)(void))
      : on_frame_available_(on_frame_available) {}

  ~CVPixelBufferSink() override { Teardown(); }

  uint32_t Configure(vlc_player::VlcFrameFormat* format) override {
    Teardown();
    if (format->width == 0 || format->height == 0) {
      return 0;
    }
    // libVLC's video thread has no autorelease pool of its own.
    @autoreleasepool {
      return ConfigurePool(format);
    }
  }

  /// libVLC's cleanup callback: drop the frames, keep the pool.
  ///
  /// Deliberately not a teardown. Changing media closes one video output and
  /// opens another, and the close is not ordered against the open - the old
  /// vout's cleanup lands *after* the new one's Configure often enough to
  /// matter. Releasing the pool here therefore pulled the new vout's buffers
  /// out from under it, and libVLC went on writing a frame into memory that
  /// no longer existed. The pool is owned by Configure and by teardown, which
  /// are the two points that know which pool they mean.
  void Cleanup() override {
    CVPixelBufferRef stale_pending = nullptr;
    CVPixelBufferRef stale_in_flight = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      std::swap(stale_pending, pending_);
      std::swap(stale_in_flight, in_flight_);
      in_flight_committed_ = false;
      in_flight_released_ = false;
    }
    if (stale_pending != nullptr) {
      CVPixelBufferRelease(stale_pending);
    }
    if (stale_in_flight != nullptr) {
      CVPixelBufferRelease(stale_in_flight);
    }
  }

  /// Releases everything, including the pool. Only safe once libVLC can no
  /// longer call in.
  void Teardown() {
    Cleanup();
    CVPixelBufferPoolRef stale_pool = nullptr;
    CFTypeRef stale_aux = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      std::swap(stale_pool, pool_);
      std::swap(stale_aux, aux_attributes_);
    }
    if (stale_pool != nullptr) {
      CVPixelBufferPoolRelease(stale_pool);
    }
    if (stale_aux != nullptr) {
      CFRelease(stale_aux);
    }
  }

  /// Hands libVLC a pool buffer to decode into, or nullptr to drop the frame.
  ///
  /// Dropping is safe here only because VlcVideoOutput points libVLC at its
  /// scratch bin whenever this returns nullptr - libVLC 3's lock callback has
  /// no way to refuse a picture on its own.
  void* Acquire(void** planes) override {
    CVPixelBufferRef abandoned = nullptr;
    CVPixelBufferRef buffer = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      // A picture libVLC decoded but never displayed is still sitting here.
      std::swap(abandoned, in_flight_);
      in_flight_committed_ = false;
      in_flight_released_ = false;

      if (pool_ != nullptr &&
          CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
              kCFAllocatorDefault, pool_,
              static_cast<CFDictionaryRef>(aux_attributes_),
              &buffer) != kCVReturnSuccess) {
        buffer = nullptr;
      }
    }
    if (abandoned != nullptr) {
      CVPixelBufferRelease(abandoned);
    }
    if (buffer == nullptr) {
      return nullptr;
    }

    if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
      CVPixelBufferRelease(buffer);
      return nullptr;
    }
    for (uint32_t plane = 0; plane < kPlaneCount; ++plane) {
      // A stride that does not match the buffer would let the decoder write
      // past the end of a row, so bin the frame rather than guess.
      if (CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) !=
          pitches_[plane]) {
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        CVPixelBufferRelease(buffer);
        return nullptr;
      }
      planes[plane] = CVPixelBufferGetBaseAddressOfPlane(buffer, plane);
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      in_flight_ = buffer;
    }
    return buffer;
  }

  void Commit(void* picture) override {
    if (picture == nullptr) {
      return;
    }
    bool publish = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (in_flight_ != picture) {
        return;
      }
      in_flight_committed_ = true;
      publish = in_flight_released_;
    }
    if (publish) {
      Publish();
    }
  }

  void Release(void* picture, void* const* planes) override {
    if (picture == nullptr) {
      return;
    }
    auto buffer = static_cast<CVPixelBufferRef>(picture);
    CVPixelBufferUnlockBaseAddress(buffer, 0);

    bool publish = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (in_flight_ != picture) {
        return;
      }
      in_flight_released_ = true;
      publish = in_flight_committed_;
    }
    if (publish) {
      Publish();
    }
  }

  /// The newest published frame, retained for the caller, or nullptr before
  /// the first one arrives.
  CVPixelBufferRef CopyPending() {
    std::lock_guard<std::mutex> lock(mutex_);
    // Deliberately kept rather than handed over: Flutter re-reads the texture
    // on resize and on any repaint that did not follow a new frame, and a
    // nullptr there paints a black hole where the video was.
    return pending_ == nullptr ? nullptr : CVPixelBufferRetain(pending_);
  }

  void Silence() {
    std::lock_guard<std::mutex> lock(mutex_);
    on_frame_available_ = nil;
  }

 private:
  uint32_t ConfigurePool(vlc_player::VlcFrameFormat* format) {
    NSDictionary* attributes = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kPixelFormat),
      (id)kCVPixelBufferWidthKey : @(format->width),
      (id)kCVPixelBufferHeightKey : @(format->height),
      // Flutter wraps the buffer in a Metal texture through
      // CVMetalTextureCache, which only works on IOSurface-backed memory.
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };

    std::lock_guard<std::mutex> lock(mutex_);
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr,
                                (__bridge CFDictionaryRef)attributes,
                                &pool_) != kCVReturnSuccess) {
      pool_ = nullptr;
      return 0;
    }

    // libVLC is told the strides once and reuses them for every picture, so
    // they have to come from a real buffer rather than from width alone -
    // CoreVideo pads rows to its own alignment.
    CVPixelBufferRef probe = nullptr;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool_,
                                           &probe) != kCVReturnSuccess) {
      CVPixelBufferPoolRelease(pool_);
      pool_ = nullptr;
      return 0;
    }
    for (uint32_t plane = 0; plane < kPlaneCount; ++plane) {
      pitches_[plane] =
          static_cast<uint32_t>(CVPixelBufferGetBytesPerRowOfPlane(probe, plane));
      lines_[plane] =
          static_cast<uint32_t>(CVPixelBufferGetHeightOfPlane(probe, plane));
      format->pitches[plane] = pitches_[plane];
      format->lines[plane] = lines_[plane];
    }
    CVPixelBufferRelease(probe);

    // Built once rather than per frame: Acquire runs on libVLC's video
    // thread, which has no autorelease pool to drain a fresh dictionary into.
    aux_attributes_ = CFBridgingRetain(@{
      (id)kCVPixelBufferPoolAllocationThresholdKey :
          @(kPoolAllocationThreshold),
    });

    std::memcpy(format->chroma, kChroma, sizeof(kChroma));
    coded_width_ = format->width;
    coded_height_ = format->height;
    return kPlaneCount;
  }

 public:
  /// The buffer dimensions libVLC asked for - the CODED size, which for a
  /// 1080p stream is 1920x1088 because the decoder pads height to a multiple
  /// of 16. Only the visible rows get written; the padding stays zero, and
  /// zero in NV12 is green. Flutter has to know this size to clip it off.
  CGSize CodedSize() {
    std::lock_guard<std::mutex> lock(mutex_);
    return CGSizeMake(coded_width_, coded_height_);
  }

 private:

  /// Moves the in-flight picture to `pending_` and wakes the embedder.
  void Publish() {
    CVPixelBufferRef replaced = nullptr;
    void (^notify)(void) = nil;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      replaced = pending_;
      pending_ = in_flight_;
      in_flight_ = nullptr;
      in_flight_committed_ = false;
      in_flight_released_ = false;
      notify = on_frame_available_;
    }
    if (replaced != nullptr) {
      CVPixelBufferRelease(replaced);
    }
    if (notify != nil) {
      @autoreleasepool {
        notify();
      }
    }
  }

  std::mutex mutex_;
  void (^on_frame_available_)(void);
  CVPixelBufferPoolRef pool_ = nullptr;
  CFTypeRef aux_attributes_ = nullptr;
  uint32_t pitches_[vlc_player::kVlcMaxPlanes] = {};
  uint32_t lines_[vlc_player::kVlcMaxPlanes] = {};
  uint32_t coded_width_ = 0;
  uint32_t coded_height_ = 0;

  /// The picture libVLC is filling. Published once it is both displayed
  /// (Commit) and finished with (Release) - libVLC 3's vmem output calls
  /// those in either order.
  CVPixelBufferRef in_flight_ = nullptr;
  bool in_flight_committed_ = false;
  bool in_flight_released_ = false;

  CVPixelBufferRef pending_ = nullptr;
};

}  // namespace

@implementation VlcTextureRenderer {
  std::unique_ptr<CVPixelBufferSink> _sink;
  std::unique_ptr<vlc_player::VlcVideoOutput> _output;
}

- (instancetype)initWithMediaPlayer:(VLCMediaPlayer *)mediaPlayer {
  self = [super init];
  if (self == nil) {
    return nil;
  }

  __weak VlcTextureRenderer *weakSelf = self;
  _sink = std::make_unique<CVPixelBufferSink>(^{
    VlcTextureRenderer *strongSelf = weakSelf;
    if (strongSelf != nil && strongSelf.onFrameAvailable != nil) {
      strongSelf.onFrameAvailable();
    }
  });

  auto *player =
      static_cast<libvlc_media_player_t *>(mediaPlayer.libVLCMediaPlayer);
  _output =
      std::make_unique<vlc_player::VlcVideoOutput>(player, _sink.get());
  return self;
}

- (NSString *)chroma {
  return @(kChroma);
}

- (CGSize)codedSize {
  return _sink == nullptr ? CGSizeZero : _sink->CodedSize();
}

- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  return _sink == nullptr ? nullptr : _sink->CopyPending();
}

- (void)detach {
  if (_output != nullptr) {
    _output->Detach();
    _output.reset();
  }
  if (_sink != nullptr) {
    _sink->Silence();
    _sink->Teardown();
  }
  self.onFrameAvailable = nil;
}

- (void)dealloc {
  [self detach];
  _sink.reset();
}

@end
