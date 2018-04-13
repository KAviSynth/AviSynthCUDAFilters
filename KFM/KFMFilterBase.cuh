
#include <stdint.h>
#include <avisynth.h>

struct FrameAnalyzeParam {
  int threshM;
  int threshS;
  int threshLS;

  FrameAnalyzeParam(int M, int S, int LS)
    : threshM(M)
    , threshS(S * 6)
    , threshLS(LS * 6)
  { }
};

class KFMFilterBase : public GenericVideoFilter {
protected:
  VideoInfo srcvi;
  int logUVx;
  int logUVy;

  template <typename pixel_t>
  void CopyFrame(PVideoFrame& src, PVideoFrame& dst, PNeoEnv env);

  template <typename pixel_t>
  void PadFrame(PVideoFrame& dst, PNeoEnv env);

  template <typename vpixel_t>
  void LaunchAnalyzeFrame(uchar4* dst, int dstPitch,
    const vpixel_t* base, const vpixel_t* sref, const vpixel_t* mref,
    int width, int height, int pitch, int threshM, int threshS, int threshLS,
    PNeoEnv env);

  template <typename pixel_t>
  void AnalyzeFrame(PVideoFrame& f0, PVideoFrame& f1, PVideoFrame& flag,
    const FrameAnalyzeParam* prmY, const FrameAnalyzeParam* prmC, PNeoEnv env);

  void MergeUVFlags(PVideoFrame& flag, PNeoEnv env);

  template <typename pixel_t>
  void MergeUVCoefs(PVideoFrame& flag, PNeoEnv env);

  template <typename pixel_t>
  void ApplyUVCoefs(PVideoFrame& flag, PNeoEnv env);

  template <typename pixel_t>
  void ExtendCoefs(PVideoFrame& src, PVideoFrame& dst, PNeoEnv env);

  template <typename pixel_t>
  void CompareFields(PVideoFrame& src, PVideoFrame& flag, PNeoEnv env);

  PVideoFrame OffsetPadFrame(const PVideoFrame& frame, PNeoEnv env);

public:
  KFMFilterBase(PClip _child);

  int __stdcall SetCacheHints(int cachehints, int frame_range);
};

static __device__ __host__ int4 CalcCombe(int4 a, int4 b, int4 c, int4 d, int4 e) {
  return abs(a + c * 4 + e - (b + d) * 3);
}

int scaleParam(float thresh, int pixelBits);

int Get8BitType(VideoInfo& vi);

PVideoFrame NewSwitchFlagFrame(VideoInfo vi, int hpad, int vpad, PNeoEnv env);

template <typename pixel_t, int fill_v>
void cpu_fill(pixel_t* dst, int width, int height, int pitch);

template <typename pixel_t, int fill_v>
__global__ void kl_fill(pixel_t* dst, int width, int height, int pitch);

template <typename pixel_t>
void cpu_copy(pixel_t* dst, const pixel_t* __restrict__ src, int width, int height, int pitch);

template <typename pixel_t>
__global__ void kl_copy(pixel_t* dst, const pixel_t* __restrict__ src, int width, int height, int pitch);

template <typename pixel_t>
void cpu_average(pixel_t* dst, const pixel_t* __restrict__ src0,
  const pixel_t* __restrict__ src1, int width, int height, int pitch);

template <typename pixel_t>
__global__ void kl_average(pixel_t* dst, const pixel_t* __restrict__ src0,
  const pixel_t* __restrict__ src1, int width, int height, int pitch);

template <typename pixel_t>
void cpu_padv(pixel_t* dst, int width, int height, int pitch, int vpad);

template <typename pixel_t>
__global__ void kl_padv(pixel_t* dst, int width, int height, int pitch, int vpad);

template <typename pixel_t>
void cpu_padh(pixel_t* dst, int width, int height, int pitch, int hpad);

template <typename pixel_t>
__global__ void kl_padh(pixel_t* dst, int width, int height, int pitch, int hpad);

template <typename pixel_t>
void cpu_copy_border(pixel_t* dst,
  const pixel_t* src, int width, int height, int pitch, int vborder);

template <typename pixel_t>
__global__ void kl_copy_border(pixel_t* dst,
  const pixel_t* __restrict__ src, int width, int height, int pitch, int vborder);

// sref��base-1���C��
template <typename vpixel_t>
void cpu_analyze_frame(uchar4* dst, int dstPitch,
  const vpixel_t* base, const vpixel_t* sref, const vpixel_t* mref,
  int width, int height, int pitch, int threshM, int threshS, int threshLS);

template <typename vpixel_t>
__global__ void kl_analyze_frame(uchar4* dst, int dstPitch,
  const vpixel_t* __restrict__ base,
  const vpixel_t* __restrict__ sref,
  const vpixel_t* __restrict__ mref,
  int width, int height, int pitch, int threshM, int threshS, int threshLS);

void cpu_merge_uvflags(uint8_t* fY,
  const uint8_t* fU, const uint8_t* fV,
  int width, int height, int pitchY, int pitchUV, int logUVx, int logUVy);

__global__ void kl_merge_uvflags(uint8_t* fY,
  const uint8_t* __restrict__ fU, const uint8_t* __restrict__ fV,
  int width, int height, int pitchY, int pitchUV, int logUVx, int logUVy);

template <typename pixel_t>
void cpu_merge_uvcoefs(pixel_t* fY,
  const pixel_t* fU, const pixel_t* fV,
  int width, int height, int pitchY, int pitchUV, int logUVx, int logUVy);

template <typename pixel_t>
__global__ void kl_merge_uvcoefs(pixel_t* fY,
  const pixel_t* __restrict__ fU, const pixel_t* __restrict__ fV,
  int width, int height, int pitchY, int pitchUV, int logUVx, int logUVy);

template <typename vpixel_t>
void cpu_and_coefs(vpixel_t* dstp, const vpixel_t* diffp,
  int width, int height, int pitch, float invcombe, float invdiff);

template <typename pixel_t>
void cpu_apply_uvcoefs_420(
  const pixel_t* fY, pixel_t* fU, pixel_t* fV,
  int widthUV, int heightUV, int pitchY, int pitchUV);

template <typename pixel_t>
__global__ void kl_apply_uvcoefs_420(
  const pixel_t* __restrict__ fY, pixel_t* fU, pixel_t* fV,
  int widthUV, int heightUV, int pitchY, int pitchUV);

template <typename vpixel_t>
void cpu_extend_coef(vpixel_t* dst, const vpixel_t* src, int width, int height, int pitch);

template <typename vpixel_t>
__global__ void kl_extend_coef(vpixel_t* dst, const vpixel_t* __restrict__ src, int width, int height, int pitch);

template <typename vpixel_t>
void cpu_calc_combe(vpixel_t* dst, const vpixel_t* src, int width, int height, int pitch);

template <typename vpixel_t>
__global__ void kl_calc_combe(vpixel_t* dst, const vpixel_t* __restrict__ src, int width, int height, int pitch);