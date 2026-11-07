#ifndef VLC_PLAYER_NATIVE_VLC_PLAYER_CORE_H_
#define VLC_PLAYER_NATIVE_VLC_PLAYER_CORE_H_

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <vlcpp/vlc.hpp>

#include "vlc_pixel_buffer_sink.h"
#include "vlc_player_types.h"
#include "vlc_video_output.h"

namespace vlc_player {

class VlcPlayerCore {
 public:
  using FrameAvailableCallback = std::function<void()>;

  explicit VlcPlayerCore(std::vector<std::string> options,
                         FrameAvailableCallback on_frame_available);
  ~VlcPlayerCore();

  VlcPlayerCore(const VlcPlayerCore&) = delete;
  VlcPlayerCore& operator=(const VlcPlayerCore&) = delete;

  bool is_valid() const;
  const std::string& error() const;

  std::string SetSource(const std::string& uri,
                        const std::vector<std::string>& headers,
                        const std::vector<std::string>& media_options,
                        int64_t start_position,
                        bool auto_play);
  std::string Play();
  std::string Pause();
  std::string Stop();
  std::string SeekTo(int64_t milliseconds);
  std::string SetVolume(int volume);
  std::string SetPlaybackSpeed(double speed);
  std::string SetAudioDelay(int64_t microseconds);
  std::string SetSubtitleDelay(int64_t microseconds);
  std::vector<uint8_t> TakeSnapshot(uint32_t width,
                                    uint32_t height,
                                    std::string* error);

  std::vector<VlcTrackDescription> GetAudioTracks();
  std::string SetAudioTrack(int id);
  std::vector<VlcTrackDescription> GetSubtitleTracks();
  std::string SetSubtitleTrack(int id);
  std::string DisableSubtitle();
  std::string AddSubtitle(const std::string& uri);
  VlcMediaInfo GetMediaInfo();
  VlcMediaStats GetMediaStats();

  VlcSnapshot Snapshot();
  bool CopyPixels(const uint8_t** out_buffer, uint32_t* width, uint32_t* height);
  void Dispose();

  // A cheap, order-sensitive fingerprint of the audio + subtitle track SET.
  //
  // Snapshot() diffs this instead of a track count: the two lists can be
  // replaced wholesale without changing how many entries they hold (an
  // adaptive rendition change, an MPEG-TS PMT update), and a count-derived
  // revision would sit still through it, leaving every consumer caching
  // GetAudioTracks() / GetSubtitleTracks() drawing the previous names with
  // nothing ticked.
  //
  // Public because that property - a same-size swap moves the number - is
  // what the native suite pins.
  static int64_t TrackSetFingerprint(
      const std::vector<VlcTrackDescription>& audio,
      const std::vector<VlcTrackDescription>& subtitles);

#ifdef VLC_PLAYER_TESTING
  VlcPixelBufferSink* FrameSinkForTesting();
  void ResizeVideoBufferForTesting(uint32_t width,
                                   uint32_t height,
                                   uint32_t pitch);
  void SimulateFrameForTesting(uint8_t value);
  const uint8_t* FrameBufferDataForTesting() const;
  size_t FrameBufferSizeForTesting() const;
  uint64_t RenderGenerationForTesting() const;
  uint64_t TextureGenerationForTesting() const;
#endif  // VLC_PLAYER_TESTING

 private:
  std::string ActiveError() const;

  static std::string StateName(libvlc_state_t state);
  static bool IsReadyState(const std::string& state);
  static bool IsLiveState(const std::string& state);
  static std::string FourCCString(uint32_t value);
  static std::string TrackTypeName(VLC::MediaTrack::Type type);
  static VlcMediaTrackInfo MediaTrackInfo(const VLC::MediaTrack& track);
  static std::vector<VlcTrackDescription> TrackDescriptions(
      const std::vector<VLC::TrackDescription>& tracks);

  FrameAvailableCallback on_frame_available_;
  std::unique_ptr<VLC::Instance> instance_;
  std::unique_ptr<VLC::MediaPlayer> player_;
  std::string init_error_;
  std::atomic<bool> disposed_{false};

  // Declared before video_output_ so the output is torn down first: Detach
  // has to stop libVLC calling in before the sink it calls into is gone.
  std::unique_ptr<VlcPixelBufferSink> frame_sink_;
  std::unique_ptr<VlcVideoOutput> video_output_;

  mutable std::mutex state_mutex_;
  int volume_ = 100;
  // TrackSetFingerprint() of the audio + spu lists seen by the last
  // Snapshot(); the revision moves when a new snapshot disagrees with it.
  // -1 is unreachable for a real fingerprint, so it means "nothing seen yet".
  int64_t last_track_fingerprint_ = -1;
  int64_t track_revision_ = 0;
  std::string state_override_;
  std::string error_code_;
  std::string error_description_;
};

}  // namespace vlc_player

#endif  // VLC_PLAYER_NATIVE_VLC_PLAYER_CORE_H_
