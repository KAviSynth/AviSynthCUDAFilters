
#include <stdint.h>
#include <avisynth.h>

#include <algorithm>
#include <memory>
#include <string>

#include "CommonFunctions.h"
#include "KFM.h"

#include "VectorFunctions.cuh"
#include "ReduceKernel.cuh"
#include "KFMFilterBase.cuh"
#include "TextOut.h"

template <typename vpixel_t>
void cpu_calc_field_diff(const vpixel_t* ptr, int nt, int width, int height, int pitch, unsigned long long int *sum)
{
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      int4 combe = CalcCombe(
        to_int(ptr[x + (y - 2) * pitch]),
        to_int(ptr[x + (y - 1) * pitch]),
        to_int(ptr[x + (y + 0) * pitch]),
        to_int(ptr[x + (y + 1) * pitch]),
        to_int(ptr[x + (y + 2) * pitch]));

      *sum += ((combe.x > nt) ? combe.x : 0);
      *sum += ((combe.y > nt) ? combe.y : 0);
      *sum += ((combe.z > nt) ? combe.z : 0);
      *sum += ((combe.w > nt) ? combe.w : 0);
    }
  }
}

enum {
  CALC_FIELD_DIFF_X = 32,
  CALC_FIELD_DIFF_Y = 16,
  CALC_FIELD_DIFF_THREADS = CALC_FIELD_DIFF_X * CALC_FIELD_DIFF_Y
};

__global__ void kl_init_uint64(uint64_t* sum)
{
  sum[threadIdx.x] = 0;
}

template <typename vpixel_t>
__global__ void kl_calculate_field_diff(const vpixel_t* ptr, int nt, int width, int height, int pitch, uint64_t* sum)
{
  int x = threadIdx.x + blockIdx.x * blockDim.x;
  int y = threadIdx.y + blockIdx.y * blockDim.y;
  int tid = threadIdx.x + threadIdx.y * CALC_FIELD_DIFF_X;

  int tmpsum = 0;
  if (x < width && y < height) {
    int4 combe = CalcCombe(
      to_int(ptr[x + (y - 2) * pitch]),
      to_int(ptr[x + (y - 1) * pitch]),
      to_int(ptr[x + (y + 0) * pitch]),
      to_int(ptr[x + (y + 1) * pitch]),
      to_int(ptr[x + (y + 2) * pitch]));

    tmpsum += ((combe.x > nt) ? combe.x : 0);
    tmpsum += ((combe.y > nt) ? combe.y : 0);
    tmpsum += ((combe.z > nt) ? combe.z : 0);
    tmpsum += ((combe.w > nt) ? combe.w : 0);
  }

  __shared__ int sbuf[CALC_FIELD_DIFF_THREADS];
  dev_reduce<int, CALC_FIELD_DIFF_THREADS, AddReducer<int>>(tid, tmpsum, sbuf);

  if (tid == 0) {
    atomicAdd(sum, tmpsum);
  }
}

class KFieldDiff : public KFMFilterBase
{
  int nt6;
  bool chroma;

  VideoInfo padvi;
  VideoInfo workvi;

  template <typename pixel_t>
  unsigned long long int CalcFieldDiff(Frame& frame, Frame& work, PNeoEnv env)
  {
    typedef typename VectorType<pixel_t>::type vpixel_t;
    const vpixel_t* srcY = frame.GetReadPtr<vpixel_t>(PLANAR_Y);
    const vpixel_t* srcU = frame.GetReadPtr<vpixel_t>(PLANAR_U);
    const vpixel_t* srcV = frame.GetReadPtr<vpixel_t>(PLANAR_V);
    unsigned long long int* sum = work.GetWritePtr<unsigned long long int>();

    int pitchY = frame.GetPitch<vpixel_t>(PLANAR_Y);
    int pitchUV = frame.GetPitch<vpixel_t>(PLANAR_U);
    int width4 = vi.width >> 2;
    int width4UV = width4 >> logUVx;
    int heightUV = vi.height >> logUVy;

    if (IS_CUDA) {
      dim3 threads(CALC_FIELD_DIFF_X, CALC_FIELD_DIFF_Y);
      dim3 blocks(nblocks(width4, threads.x), nblocks(vi.height, threads.y));
      dim3 blocksUV(nblocks(width4UV, threads.x), nblocks(heightUV, threads.y));
      kl_init_uint64 << <1, 1 >> > (sum);
      DEBUG_SYNC;
      kl_calculate_field_diff << <blocks, threads >> >(srcY, nt6, width4, vi.height, pitchY, sum);
      DEBUG_SYNC;
      if (chroma) {
        kl_calculate_field_diff << <blocksUV, threads >> > (srcU, nt6, width4UV, heightUV, pitchUV, sum);
        DEBUG_SYNC;
        kl_calculate_field_diff << <blocksUV, threads >> > (srcV, nt6, width4UV, heightUV, pitchUV, sum);
        DEBUG_SYNC;
      }
      long long int result;
      CUDA_CHECK(cudaMemcpy(&result, sum, sizeof(*sum), cudaMemcpyDeviceToHost));
      return result;
    }
    else {
      *sum = 0;
      cpu_calc_field_diff(srcY, nt6, width4, vi.height, pitchY, sum);
      if (chroma) {
        cpu_calc_field_diff(srcU, nt6, width4UV, heightUV, pitchUV, sum);
        cpu_calc_field_diff(srcV, nt6, width4UV, heightUV, pitchUV, sum);
      }
      return *sum;
    }
  }

  template <typename pixel_t>
  double InternalFieldDiff(int n, PNeoEnv env)
  {
    Frame src = child->GetFrame(n, env);
    Frame padded = Frame(env->NewVideoFrame(padvi), VPAD);
    Frame work = env->NewVideoFrame(workvi);

    CopyFrame<pixel_t>(src, padded, env);
    PadFrame<pixel_t>(padded, env);
    auto raw = CalcFieldDiff<pixel_t>(padded, work, env);
    raw /= 6; // 計算式から

    int shift = vi.BitsPerComponent() - 8; // 8bitに合わせる
    return (double)(raw >> shift);
  }

public:
  KFieldDiff(PClip clip, float nt, bool chroma)
    : KFMFilterBase(clip)
    , nt6(scaleParam(nt * 6, vi.BitsPerComponent()))
    , chroma(chroma)
    , padvi(vi)
  {
    padvi.height += VPAD * 2;

    int work_bytes = sizeof(long long int);
    workvi.pixel_type = VideoInfo::CS_BGR32;
    workvi.width = 4;
    workvi.height = nblocks(work_bytes, workvi.width * 4);
  }

  AVSValue ConditionalFieldDiff(int n, IScriptEnvironment* env_)
  {
    PNeoEnv env = env_;

    int pixelSize = vi.ComponentSize();
    switch (pixelSize) {
    case 1:
      return InternalFieldDiff<uint8_t>(n, env);
    case 2:
      return InternalFieldDiff<uint16_t>(n, env);
    default:
      env->ThrowError("[KFieldDiff] Unsupported pixel format");
    }

    return 0;
  }

  static AVSValue __cdecl CFunc(AVSValue args, void* user_data, IScriptEnvironment* env)
  {
    AVSValue cnt = env->GetVar("current_frame");
    if (!cnt.IsInt()) {
      env->ThrowError("[KCFieldDiff] This filter can only be used within ConditionalFilter!");
    }
    int n = cnt.AsInt();
    std::unique_ptr<KFieldDiff> f = std::unique_ptr<KFieldDiff>(new KFieldDiff(
      args[0].AsClip(),    // clip
      (float)args[1].AsFloat(3),    // nt
      args[2].AsBool(true) // chroma
    ));
    return f->ConditionalFieldDiff(n, env);
  }
};


void cpu_init_block_sum(int *sumAbs, int* sumSig, int* maxSum, int length)
{
  for (int x = 0; x < length; ++x) {
    sumAbs[x] = 0;
    sumSig[x] = 0;
  }
  maxSum[0] = 0;
}

template <typename vpixel_t, int BLOCK_SIZE, int TH_Z>
void cpu_add_block_sum(
  const vpixel_t* src0,
  const vpixel_t* src1,
  int width, int height, int pitch,
  int blocks_w, int blocks_h, int block_pitch,
  int *sumAbs, int* sumSig)
{
  for (int by = 0; by < blocks_h; ++by) {
    for (int bx = 0; bx < blocks_w; ++bx) {
      int abssum = 0;
      int sigsum = 0;
      for (int ty = 0; ty < BLOCK_SIZE; ++ty) {
        for (int tx = 0; tx < BLOCK_SIZE / 4; ++tx) {
          int x = tx + bx * BLOCK_SIZE / 4;
          int y = ty + by * BLOCK_SIZE;
          if (x < width && y < height) {
            auto s0 = src0[x + y * pitch];
            auto s1 = src1[x + y * pitch];
            auto t0 = absdiff(s0, s1);
            auto t1 = to_int(s0) - to_int(s1);
            abssum += t0.x + t0.y + t0.z + t0.w;
            sigsum += t1.x + t1.y + t1.z + t1.w;
          }
        }
      }
      sumAbs[bx + by * block_pitch] += abssum;
      sumSig[bx + by * block_pitch] += sigsum;
    }
  }
}

__global__ void kl_init_block_sum(int *sumAbs, int* sumSig, int* maxSum, int length)
{
  int x = threadIdx.x + blockIdx.x * blockDim.x;
  if (x < length) {
    sumAbs[x] = 0;
    sumSig[x] = 0;
  }
  if (x == 0) {
    maxSum[0] = 0;
  }
}

template <typename vpixel_t, int BLOCK_SIZE, int TH_Z>
__global__ void kl_add_block_sum(
  const vpixel_t* __restrict__ src0,
  const vpixel_t* __restrict__ src1,
  int width, int height, int pitch,
  int blocks_w, int blocks_h, int block_pitch,
  int *sumAbs, int* sumSig)
{
  // blockDim.x == BLOCK_SIZE/4
  // blockDim.y == BLOCK_SIZE
  enum { PIXELS = BLOCK_SIZE * BLOCK_SIZE / 4 };
  int bx = threadIdx.z + TH_Z * blockIdx.x;
  int by = blockIdx.y;
  int x = threadIdx.x + (BLOCK_SIZE / 4) * bx;
  int y = threadIdx.y + BLOCK_SIZE * by;
  int tz = threadIdx.z;
  int tid = threadIdx.x + threadIdx.y * blockDim.x;

  int abssum = 0;
  int sigsum = 0;
  if (x < width && y < height) {
    auto s0 = src0[x + y * pitch];
    auto s1 = src1[x + y * pitch];
    auto t0 = absdiff(s0, s1);
    auto t1 = to_int(s0) - to_int(s1);
    abssum = t0.x + t0.y + t0.z + t0.w;
    sigsum = t1.x + t1.y + t1.z + t1.w;
  }

  __shared__ int sbuf[TH_Z][PIXELS];
  dev_reduce<int, PIXELS, AddReducer<int>>(tid, abssum, sbuf[tz]);
  dev_reduce<int, PIXELS, AddReducer<int>>(tid, sigsum, sbuf[tz]);

  if (tid == 0) {
    sumAbs[bx + by * block_pitch] += abssum;
    sumSig[bx + by * block_pitch] += sigsum;
  }
}

template <typename vpixel_t, int BLOCK_SIZE, int TH_Z>
void launch_add_block_sum(
  const vpixel_t* src0,
  const vpixel_t* src1,
  int width, int height, int pitch,
  int blocks_w, int blocks_h, int block_pitch,
  int *sumAbs, int* sumSig)
{
  dim3 threads(BLOCK_SIZE >> 2, BLOCK_SIZE, TH_Z);
  dim3 blocks(nblocks(blocks_w, TH_Z), blocks_h);
  kl_add_block_sum<vpixel_t, BLOCK_SIZE, TH_Z> << <blocks, threads >> >(src0, src1,
    width, height, pitch, blocks_w, blocks_h, block_pitch, sumAbs, sumSig);
}

void cpu_block_sum_max(
  const int4* sumAbs, const int4* sumSig,
  int blocks_w, int blocks_h, int block_pitch,
  int* highest_sum)
{
  int tmpmax = 0;
  for (int y = 0; y < blocks_h; ++y) {
    for (int x = 0; x < blocks_w; ++x) {
      int4 metric = sumAbs[x + y * block_pitch] + sumSig[x + y * block_pitch] * 4;
      tmpmax = max(tmpmax, max(max(metric.x, metric.y), max(metric.z, metric.w)));
    }
  }
  *highest_sum = tmpmax;
}

__global__ void kl_block_sum_max(
  const int4* sumAbs, const int4* sumSig,
  int blocks_w, int blocks_h, int block_pitch,
  int* highest_sum)
{
  int x = threadIdx.x + blockIdx.x * blockDim.x;
  int y = threadIdx.y + blockIdx.y * blockDim.y;
  int tid = threadIdx.x + threadIdx.y * CALC_FIELD_DIFF_X;

  int tmpmax = 0;
  if (x < blocks_w && y < blocks_h) {
    int4 metric = sumAbs[x + y * block_pitch] + sumSig[x + y * block_pitch] * 4;
    tmpmax = max(max(metric.x, metric.y), max(metric.z, metric.w));
  }

  __shared__ int sbuf[CALC_FIELD_DIFF_THREADS];
  dev_reduce<int, CALC_FIELD_DIFF_THREADS, MaxReducer<int>>(tid, tmpmax, sbuf);

  if (tid == 0) {
    atomicMax(highest_sum, tmpmax);
  }
}

class KFrameDiffDup : public KFMFilterBase
{
  bool chroma;
  int blocksize;

  int logUVx;
  int logUVy;

  int th_z, th_uv_z;
  int blocks_w, blocks_h, block_pitch;
  VideoInfo workvi;

  enum { THREADS = 256 };

  // returns argmax(subAbs + sumSig * 4)
  template <typename pixel_t>
  int CalcFrameDiff(Frame& src0, Frame& src1, Frame& work, PNeoEnv env)
  {
    typedef typename VectorType<pixel_t>::type vpixel_t;
    const vpixel_t* src0Y = src0.GetReadPtr<vpixel_t>(PLANAR_Y);
    const vpixel_t* src0U = src0.GetReadPtr<vpixel_t>(PLANAR_U);
    const vpixel_t* src0V = src0.GetReadPtr<vpixel_t>(PLANAR_V);
    const vpixel_t* src1Y = src1.GetReadPtr<vpixel_t>(PLANAR_Y);
    const vpixel_t* src1U = src1.GetReadPtr<vpixel_t>(PLANAR_U);
    const vpixel_t* src1V = src1.GetReadPtr<vpixel_t>(PLANAR_V);
    int* sumAbs = work.GetWritePtr<int>();
    int* sumSig = &sumAbs[block_pitch * blocks_h];
    int* maxSum = &sumSig[block_pitch * blocks_h];

    int pitchY = src0.GetPitch<vpixel_t>(PLANAR_Y);
    int pitchUV = src0.GetPitch<vpixel_t>(PLANAR_U);
    int width4 = vi.width >> 2;
    int width4UV = width4 >> logUVx;
    int heightUV = vi.height >> logUVy;
    int blocks_w4 = blocks_w >> 2;
    int block_pitch4 = block_pitch >> 2;

    void(*table[2][4])(
      const vpixel_t* src0,
      const vpixel_t* src1,
      int width, int height, int pitch,
      int blocks_w, int blocks_h, int block_pitch,
      int *sumAbs, int* sumSig) =
    {
      {
        launch_add_block_sum<vpixel_t, 32, THREADS / (32 * (32 / 4))>,
        launch_add_block_sum<vpixel_t, 16, THREADS / (16 * (16 / 4))>,
        launch_add_block_sum<vpixel_t, 8, THREADS / (8 * (8 / 4))>,
        launch_add_block_sum<vpixel_t, 4, THREADS / (4 * (4 / 4))>,
      },
      {
        cpu_add_block_sum<vpixel_t, 32, THREADS / (32 * (32 / 4))>,
        cpu_add_block_sum<vpixel_t, 16, THREADS / (16 * (16 / 4))>,
        cpu_add_block_sum<vpixel_t, 8, THREADS / (8 * (8 / 4))>,
        cpu_add_block_sum<vpixel_t, 4, THREADS / (4 * (4 / 4))>,
      }
    };

    int f_idx;
    switch (blocksize) {
    case 32: f_idx = 0; break;
    case 16: f_idx = 1; break;
    case 8: f_idx = 2; break;
    }

    if (IS_CUDA) {
      kl_init_block_sum << <64, nblocks(block_pitch * blocks_h, 64) >> > (
        sumAbs, sumSig, maxSum, block_pitch * blocks_h);
      DEBUG_SYNC;
      table[0][f_idx](src0Y, src1Y,
        width4, vi.height, pitchY, blocks_w, blocks_h, block_pitch, sumAbs, sumSig);
      DEBUG_SYNC;
      if (chroma) {
        table[0][f_idx + logUVx](src0U, src1U,
          width4UV, heightUV, pitchUV, blocks_w, blocks_h, block_pitch, sumAbs, sumSig);
        DEBUG_SYNC;
        table[0][f_idx + logUVx](src0V, src1V,
          width4UV, heightUV, pitchUV, blocks_w, blocks_h, block_pitch, sumAbs, sumSig);
        DEBUG_SYNC;
      }
      dim3 threads(CALC_FIELD_DIFF_X, CALC_FIELD_DIFF_Y);
      dim3 blocks(nblocks(blocks_w4, threads.x), nblocks(blocks_h, threads.y));
      kl_block_sum_max << <blocks, threads >> > (
        (int4*)sumAbs, (int4*)sumSig, blocks_w4, blocks_h, block_pitch4, maxSum);
      int result;
      CUDA_CHECK(cudaMemcpy(&result, maxSum, sizeof(int), cudaMemcpyDeviceToHost));
      return result;
    }
    else {
      cpu_init_block_sum(
        sumAbs, sumSig, maxSum, block_pitch * blocks_h);
      table[1][f_idx](src0Y, src1Y,
        width4, vi.height, pitchY, blocks_w, blocks_h, block_pitch, sumAbs, sumSig);
      if (chroma) {
        table[1][f_idx + logUVx](src0U, src1U,
          width4UV, heightUV, pitchUV, blocks_w, blocks_h, block_pitch, sumAbs, sumSig);
        table[1][f_idx + logUVx](src0V, src1V,
          width4UV, heightUV, pitchUV, blocks_w, blocks_h, block_pitch, sumAbs, sumSig);
      }
      cpu_block_sum_max(
        (int4*)sumAbs, (int4*)sumSig, blocks_w4, blocks_h, block_pitch4, maxSum);
      return *maxSum;
    }
  }

  template <typename pixel_t>
  double InternalFrameDiff(int n, PNeoEnv env)
  {
    Frame src0 = child->GetFrame(clamp(n - 1, 0, vi.num_frames - 1), env);
    Frame src1 = child->GetFrame(clamp(n, 0, vi.num_frames - 1), env);
    Frame work = env->NewVideoFrame(workvi);

    int diff = CalcFrameDiff<pixel_t>(src0, src1, work, env);

    int shift = vi.BitsPerComponent() - 8;

    // dup232aだとこうだけど、この計算式はおかしいと思うので修正
    //return  diff / (64.0 * (235 << shift) * blocksize) * 100.0;
    return  diff / (2.0 * (235 << shift) * blocksize * blocksize) * 100.0;
  }

public:
  KFrameDiffDup(PClip clip, bool chroma, int blocksize)
    : KFMFilterBase(clip)
    , chroma(chroma)
    , blocksize(blocksize)
    , logUVx(vi.GetPlaneWidthSubsampling(PLANAR_U))
    , logUVy(vi.GetPlaneHeightSubsampling(PLANAR_U))
  {
    blocks_w = nblocks(vi.width, blocksize);
    blocks_h = nblocks(vi.height, blocksize);

    th_z = THREADS / (blocksize * (blocksize / 4));
    th_uv_z = th_z * (chroma ? (1 << (logUVx + logUVy)) : 1);

    int block_align = max(4, th_uv_z);
    block_pitch = nblocks(blocks_w, block_align) * block_align;

    int work_bytes = sizeof(int) * block_pitch * blocks_h * 2 + sizeof(int);
    workvi.pixel_type = VideoInfo::CS_BGR32;
    workvi.width = 256;
    workvi.height = nblocks(work_bytes, workvi.width * 4);
  }

  AVSValue ConditionalFrameDiff(int n, IScriptEnvironment* env_)
  {
    PNeoEnv env = env_;

    int pixelSize = vi.ComponentSize();
    switch (pixelSize) {
    case 1:
      return InternalFrameDiff<uint8_t>(n, env);
    case 2:
      return InternalFrameDiff<uint16_t>(n, env);
    default:
      env->ThrowError("[KFrameDiffDup] Unsupported pixel format");
    }

    return 0;
  }

  static AVSValue __cdecl CFunc(AVSValue args, void* user_data, IScriptEnvironment* env)
  {
    AVSValue cnt = env->GetVar("current_frame");
    if (!cnt.IsInt()) {
      env->ThrowError("[KFrameDiffDup] This filter can only be used within ConditionalFilter!");
    }
    int n = cnt.AsInt();
    std::unique_ptr<KFrameDiffDup> f = std::unique_ptr<KFrameDiffDup>(new KFrameDiffDup(
      args[0].AsClip(),     // clip
      args[1].AsBool(true), // chroma
      args[2].AsInt(32)     // blocksize
    ));
    return f->ConditionalFrameDiff(n, env);
  }
};

__host__ __device__ int dev_limitter(int x, int nmin, int range) {
  return (x == 128)
    ? 128 
    : ((x < 128)
      ? ((((127 - range) < x)&(x < (128 - nmin))) ? 0 : 56)
      : ((((128 + nmin) < x)&(x < (129 + range))) ? 255 : 199));
}

void cpu_noise_clip(uchar4* dst, const uchar4* src, const uchar4* noise,
  int width, int height, int pitch, int nmin, int range)
{
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      auto s = (to_int(src[x + y * pitch]) - to_int(noise[x + y * pitch]) + 256) >> 1;
      int4 tmp = {
        dev_limitter(s.x, nmin, range),
        dev_limitter(s.y, nmin, range),
        dev_limitter(s.z, nmin, range),
        dev_limitter(s.w, nmin, range)
      };
      dst[x + y * pitch] = VHelper<uchar4>::cast_to(tmp);
    }
  }
}

__global__ void kl_noise_clip(uchar4* dst, const uchar4* src, const uchar4* noise,
  int width, int height, int pitch, int nmin, int range)
{
  int x = threadIdx.x + blockIdx.x * blockDim.x;
  int y = threadIdx.y + blockIdx.y * blockDim.y;

  if (x < width && y < height) {
    auto s = (to_int(src[x + y * pitch]) - to_int(noise[x + y * pitch]) + 256) >> 1;
    int4 tmp = {
      dev_limitter(s.x, nmin, range),
      dev_limitter(s.y, nmin, range),
      dev_limitter(s.z, nmin, range),
      dev_limitter(s.w, nmin, range)
    };
    dst[x + y * pitch] = VHelper<uchar4>::cast_to(tmp);
  }
}

class KNoiseClip : public KFMFilterBase
{
  PClip noiseclip;

  int range_y;
  int range_uv;
  int nmin_y;
  int nmin_uv;

  PVideoFrame GetFrameT(int n, PNeoEnv env)
  {
    typedef typename VectorType<uint8_t>::type vpixel_t;

    Frame src = child->GetFrame(n, env);
    Frame noise = noiseclip->GetFrame(n, env);
    Frame dst = env->NewVideoFrame(vi);

    const vpixel_t* srcY = src.GetReadPtr<vpixel_t>(PLANAR_Y);
    const vpixel_t* srcU = src.GetReadPtr<vpixel_t>(PLANAR_U);
    const vpixel_t* srcV = src.GetReadPtr<vpixel_t>(PLANAR_V);
    const vpixel_t* noiseY = noise.GetReadPtr<vpixel_t>(PLANAR_Y);
    const vpixel_t* noiseU = noise.GetReadPtr<vpixel_t>(PLANAR_U);
    const vpixel_t* noiseV = noise.GetReadPtr<vpixel_t>(PLANAR_V);
    vpixel_t* dstY = dst.GetWritePtr<vpixel_t>(PLANAR_Y);
    vpixel_t* dstU = dst.GetWritePtr<vpixel_t>(PLANAR_U);
    vpixel_t* dstV = dst.GetWritePtr<vpixel_t>(PLANAR_V);

    int pitchY = src.GetPitch<vpixel_t>(PLANAR_Y);
    int pitchUV = src.GetPitch<vpixel_t>(PLANAR_U);
    int width = src.GetWidth<vpixel_t>(PLANAR_Y);
    int widthUV = src.GetWidth<vpixel_t>(PLANAR_U);
    int height = src.GetHeight(PLANAR_Y);
    int heightUV = src.GetHeight(PLANAR_U);

    if (IS_CUDA) {
      dim3 threads(32, 8);
      dim3 blocks(nblocks(width, threads.x), nblocks(height, threads.y));
      dim3 blocksUV(nblocks(widthUV, threads.x), nblocks(heightUV, threads.y));
      kl_noise_clip << <blocks, threads >> >(dstY, srcY, noiseY, width, height, pitchY, nmin_y, range_y);
      DEBUG_SYNC;
      kl_noise_clip << <blocksUV, threads >> >(dstU, srcU, noiseU, widthUV, heightUV, pitchUV, nmin_uv, range_uv);
      DEBUG_SYNC;
      kl_noise_clip << <blocksUV, threads >> >(dstV, srcV, noiseV, widthUV, heightUV, pitchUV, nmin_uv, range_uv);
      DEBUG_SYNC;
    }
    else {
      cpu_noise_clip(dstY, srcY, noiseY, width, height, pitchY, nmin_y, range_y);
      cpu_noise_clip(dstU, srcU, noiseU, widthUV, heightUV, pitchUV, nmin_uv, range_uv);
      cpu_noise_clip(dstV, srcV, noiseV, widthUV, heightUV, pitchUV, nmin_uv, range_uv);
    }

    return dst.frame;
  }
public:
  KNoiseClip(PClip src, PClip noise,
    int nmin_y, int range_y, int nmin_uv, int range_uv, IScriptEnvironment* env)
    : KFMFilterBase(src)
    , noiseclip(noise)
    , range_y(range_y)
    , range_uv(range_uv)
    , nmin_y(nmin_y)
    , nmin_uv(nmin_uv)
  {
    VideoInfo noisevi = noiseclip->GetVideoInfo();

    if (vi.width & 3) env->ThrowError("[KNoiseClip]: width must be multiple of 4");
    if (vi.height & 3) env->ThrowError("[KNoiseClip]: height must be multiple of 4");
    if (vi.width != noisevi.width || vi.height != noisevi.height) {
      env->ThrowError("[KNoiseClip]: src and noiseclip must be same resoluction");
    }
  }

  PVideoFrame __stdcall GetFrame(int n, IScriptEnvironment* env_)
  {
    PNeoEnv env = env_;

    int pixelSize = vi.ComponentSize();
    switch (pixelSize) {
    case 1:
      return GetFrameT(n, env);
    //case 2:
    //  dst = InternalGetFrame<uint16_t>(n60, fmframe, frameType, env);
    //  break;
    default:
      env->ThrowError("[KNoiseClip] Unsupported pixel format");
      break;
    }

    return PVideoFrame();
  }

  static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
  {
    return new KNoiseClip(
      args[0].AsClip(),       // src
      args[1].AsClip(),       // noise
      args[2].AsInt(1),       // nmin_y
      args[3].AsInt(128),     // range_y
      args[4].AsInt(1),       // nmin_uv
      args[5].AsInt(128),     // range_uv
      env
    );
  }
};


__host__ __device__ int dev_horizontal_sum(int4 s) {
  return s.x + s.y + s.z + s.w;
}

void cpu_analyze_noise(uint64_t* result,
  const uchar4* src0, const uchar4* src1, const uchar4* src2,
  int width, int height, int pitch)
{
  uint64_t sum0 = 0, sum1 = 0, sumR0 = 0, sumR1 = 0;
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      auto s0 = to_int(src0[x + y * pitch]);
      auto s1 = to_int(src1[x + y * pitch]);
      auto s2 = to_int(src2[x + y * pitch]);

      sum0 += dev_horizontal_sum(abs(s0 + (-128)));
      sum1 += dev_horizontal_sum(abs(s1 + (-128)));
      sumR0 += dev_horizontal_sum(abs(s1 - s0));
      sumR1 += dev_horizontal_sum(abs(s2 - s1));
    }
  }
  result[0] += sum0;
  result[1] += sum1;
  result[2] += sumR0;
  result[3] += sumR1;
}

__global__ void kl_analyze_noise(
  uint64_t* result,
  const uchar4* src0, const uchar4* src1, const uchar4* src2,
  int width, int height, int pitch)
{
  int x = threadIdx.x + blockIdx.x * blockDim.x;
  int y = threadIdx.y + blockIdx.y * blockDim.y;
  int tid = threadIdx.x + threadIdx.y * CALC_FIELD_DIFF_X;

  int sum[4] = { 0 };
  if (x < width && y < height) {
    auto s0 = to_int(src0[x + y * pitch]);
    auto s1 = to_int(src1[x + y * pitch]);
    auto s2 = to_int(src2[x + y * pitch]);

    sum[0] = dev_horizontal_sum(abs(s0 + (-128)));
    sum[1] = dev_horizontal_sum(abs(s1 + (-128)));
    sum[2] = dev_horizontal_sum(abs(s1 - s0));
    sum[3] = dev_horizontal_sum(abs(s2 - s1));
  }

  __shared__ int sbuf[CALC_FIELD_DIFF_THREADS * 4];
  dev_reduceN<int, 4, CALC_FIELD_DIFF_THREADS, AddReducer<int>>(tid, sum, sbuf);

  if (tid == 0) {
    atomicAdd(&result[0], sum[0]);
    atomicAdd(&result[1], sum[1]);
    atomicAdd(&result[2], sum[2]);
    atomicAdd(&result[3], sum[3]);
  }
}

template <typename vpixel_t>
void cpu_analyze_diff(
  uint64_t* result, const vpixel_t* f0, const vpixel_t* f1,
  int width, int height, int pitch)
{
  uint64_t sum0 = 0, sum1 = 0;
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      int4 a = to_int(f0[x + (y - 2) * pitch]);
      int4 b = to_int(f0[x + (y - 1) * pitch]);
      int4 c = to_int(f0[x + (y + 0) * pitch]);
      int4 d = to_int(f0[x + (y + 1) * pitch]);
      int4 e = to_int(f0[x + (y + 2) * pitch]);

      // 現在のフレーム(f0)
      sum0 += dev_horizontal_sum(CalcCombe(a, b, c, d, e));

      // TFF前提
      // 現在のフレームのボトムフィールド（奇数ライン）と次のフレームのトップフィールド（偶数ライン）
      if (y & 1) {
        // yは奇数ライン
        a = to_int(f0[x + (y - 2) * pitch]);
        b = to_int(f1[x + (y - 1) * pitch]);
        c = to_int(f0[x + (y + 0) * pitch]);
        d = to_int(f1[x + (y + 1) * pitch]);
        e = to_int(f0[x + (y + 2) * pitch]);
        sum1 += dev_horizontal_sum(CalcCombe(a, b, c, d, e));
      }
      else {
        // yは偶数ライン
        a = to_int(f1[x + (y - 2) * pitch]);
        b = to_int(f0[x + (y - 1) * pitch]);
        c = to_int(f1[x + (y + 0) * pitch]);
        d = to_int(f0[x + (y + 1) * pitch]);
        e = to_int(f1[x + (y + 2) * pitch]);
        sum1 += dev_horizontal_sum(CalcCombe(a, b, c, d, e));
      }
    }
  }
  result[0] += sum0;
  result[1] += sum1;
}

template <typename vpixel_t>
__global__ void kl_analyze_diff(
  uint64_t* result, const vpixel_t* f0, const vpixel_t* f1,
  int width, int height, int pitch)
{
  int x = threadIdx.x + blockIdx.x * blockDim.x;
  int y = threadIdx.y + blockIdx.y * blockDim.y;
  int tid = threadIdx.x + threadIdx.y * CALC_FIELD_DIFF_X;

  int sum[2] = { 0 };
  if (x < width && y < height) {
    int4 a = to_int(f0[x + (y - 2) * pitch]);
    int4 b = to_int(f0[x + (y - 1) * pitch]);
    int4 c = to_int(f0[x + (y + 0) * pitch]);
    int4 d = to_int(f0[x + (y + 1) * pitch]);
    int4 e = to_int(f0[x + (y + 2) * pitch]);

    // 現在のフレーム(f0)
    sum[0] = dev_horizontal_sum(CalcCombe(a, b, c, d, e));

    // TFF前提
    // 現在のフレームのボトムフィールド（奇数ライン）と次のフレームのトップフィールド（偶数ライン）
    if (y & 1) {
      // yは奇数ライン
      // ↓必要なくても読むのをやめるとレジスタ使用数が25->32に増える
      a = to_int(f0[x + (y - 2) * pitch]);
      b = to_int(f1[x + (y - 1) * pitch]);
      c = to_int(f0[x + (y + 0) * pitch]);
      d = to_int(f1[x + (y + 1) * pitch]);
      e = to_int(f0[x + (y + 2) * pitch]);
      // ↓この行をifの外に持っていくとレジスタ使用数が25->39に増える
      sum[1] = dev_horizontal_sum(CalcCombe(a, b, c, d, e));
    }
    else {
      // yは偶数ライン
      // ↓必要なくても読むのをやめるとレジスタ使用数が25->32に増える
      a = to_int(f1[x + (y - 2) * pitch]);
      b = to_int(f0[x + (y - 1) * pitch]);
      c = to_int(f1[x + (y + 0) * pitch]);
      d = to_int(f0[x + (y + 1) * pitch]);
      e = to_int(f1[x + (y + 2) * pitch]);
      // ↓この行をifの外に持っていくとレジスタ使用数が25->39に増える
      sum[1] = dev_horizontal_sum(CalcCombe(a, b, c, d, e));
    }
  }

  __shared__ int sbuf[CALC_FIELD_DIFF_THREADS * 2];
  dev_reduceN<int, 2, CALC_FIELD_DIFF_THREADS, AddReducer<int>>(tid, sum, sbuf);

  if (tid == 0) {
    atomicAdd(&result[0], sum[0]);
    atomicAdd(&result[1], sum[1]);
  }
}

template __global__ void kl_analyze_diff(
  uint64_t* result, const uchar4* f0, const uchar4* f1,
  int width, int height, int pitch);

struct NoiseResult {
  uint64_t noise0, noise1;
  uint64_t noiseR0, noiseR1;
  uint64_t diff0, diff1;
};

struct UCFNoiseMeta {
  enum
  {
    VERSION = 1,
    MAGIC_KEY = 0x39EDF8,
  };
  int nMagicKey;
  int nVersion;

  int srcw, srch;
  int srcUVw, srcUVh;
  int noisew, noiseh;
  int noiseUVw, noiseUVh;

  UCFNoiseMeta()
    : nMagicKey(MAGIC_KEY)
    , nVersion(VERSION)
  { }

  static const UCFNoiseMeta* GetParam(const VideoInfo& vi, PNeoEnv env)
  {
    if (vi.sample_type != MAGIC_KEY) {
      env->ThrowError("Invalid source (sample_type signature does not match)");
    }
    const UCFNoiseMeta* param = (const UCFNoiseMeta*)(void*)vi.num_audio_samples;
    if (param->nMagicKey != MAGIC_KEY) {
      env->ThrowError("Invalid source (magic key does not match)");
    }
    return param;
  }

  static void SetParam(VideoInfo& vi, const UCFNoiseMeta* param)
  {
    vi.audio_samples_per_second = 0; // kill audio
    vi.sample_type = MAGIC_KEY;
    vi.num_audio_samples = (size_t)param;
  }
};

class KAnalyzeNoise : public KFMFilterBase
{
  PClip noiseclip;
  PClip superclip;

  UCFNoiseMeta meta;

  VideoInfo srcvi;
  VideoInfo padvi;

  void InitAnalyze(uint64_t* result, PNeoEnv env) {
    if (IS_CUDA) {
      kl_init_uint64 << <1, sizeof(NoiseResult) * 2 /sizeof(uint64_t) >> > (result);
      DEBUG_SYNC;
    }
    else {
      memset(result, 0x00, sizeof(NoiseResult) * 2);
    }
  }

  void AnalyzeNoise(uint64_t* resultY, uint64_t* resultUV, Frame noise0, Frame noise1, Frame noise2, PNeoEnv env)
  {
    typedef typename VectorType<uint8_t>::type vpixel_t;

    const vpixel_t* src0Y = noise0.GetReadPtr<vpixel_t>(PLANAR_Y);
    const vpixel_t* src0U = noise0.GetReadPtr<vpixel_t>(PLANAR_U);
    const vpixel_t* src0V = noise0.GetReadPtr<vpixel_t>(PLANAR_V);
    const vpixel_t* src1Y = noise1.GetReadPtr<vpixel_t>(PLANAR_Y);
    const vpixel_t* src1U = noise1.GetReadPtr<vpixel_t>(PLANAR_U);
    const vpixel_t* src1V = noise1.GetReadPtr<vpixel_t>(PLANAR_V);
    const vpixel_t* src2Y = noise2.GetReadPtr<vpixel_t>(PLANAR_Y);
    const vpixel_t* src2U = noise2.GetReadPtr<vpixel_t>(PLANAR_U);
    const vpixel_t* src2V = noise2.GetReadPtr<vpixel_t>(PLANAR_V);

    int pitchY = noise0.GetPitch<vpixel_t>(PLANAR_Y);
    int pitchUV = noise0.GetPitch<vpixel_t>(PLANAR_U);
    int width = noise0.GetWidth<vpixel_t>(PLANAR_Y);
    int widthUV = noise0.GetWidth<vpixel_t>(PLANAR_U);
    int height = noise0.GetHeight(PLANAR_Y);
    int heightUV = noise0.GetHeight(PLANAR_U);

    if (IS_CUDA) {
      dim3 threads(CALC_FIELD_DIFF_X, CALC_FIELD_DIFF_Y);
      dim3 blocks(nblocks(width, threads.x), nblocks(height, threads.y));
      dim3 blocksUV(nblocks(widthUV, threads.x), nblocks(heightUV, threads.y));
      kl_analyze_noise << <blocks, threads >> >(resultY, src0Y, src1Y, src2Y, width, height, pitchY);
      DEBUG_SYNC;
      kl_analyze_noise << <blocksUV, threads >> >(resultUV, src0U, src1U, src2U, widthUV, heightUV, pitchUV);
      DEBUG_SYNC;
      kl_analyze_noise << <blocksUV, threads >> >(resultUV, src0V, src1V, src2V, widthUV, heightUV, pitchUV);
      DEBUG_SYNC;
    }
    else {
      cpu_analyze_noise(resultY, src0Y, src1Y, src2Y, width, height, pitchY);
      cpu_analyze_noise(resultUV, src0U, src1U, src2U, widthUV, heightUV, pitchUV);
      cpu_analyze_noise(resultUV, src0V, src1V, src2V, widthUV, heightUV, pitchUV);
    }
  }

  void AnalyzeDiff(uint64_t* resultY, uint64_t* resultUV, Frame frame0, Frame frame1, PNeoEnv env)
  {
    typedef typename VectorType<uint8_t>::type vpixel_t;

    const vpixel_t* src0Y = frame0.GetReadPtr<vpixel_t>(PLANAR_Y);
    const vpixel_t* src0U = frame0.GetReadPtr<vpixel_t>(PLANAR_U);
    const vpixel_t* src0V = frame0.GetReadPtr<vpixel_t>(PLANAR_V);
    const vpixel_t* src1Y = frame1.GetReadPtr<vpixel_t>(PLANAR_Y);
    const vpixel_t* src1U = frame1.GetReadPtr<vpixel_t>(PLANAR_U);
    const vpixel_t* src1V = frame1.GetReadPtr<vpixel_t>(PLANAR_V);

    int pitchY = frame0.GetPitch<vpixel_t>(PLANAR_Y);
    int pitchUV = frame0.GetPitch<vpixel_t>(PLANAR_U);
    int width = frame0.GetWidth<vpixel_t>(PLANAR_Y);
    int widthUV = frame0.GetWidth<vpixel_t>(PLANAR_U);
    int height = frame0.GetHeight(PLANAR_Y);
    int heightUV = frame0.GetHeight(PLANAR_U);

    if (IS_CUDA) {
      dim3 threads(CALC_FIELD_DIFF_X, CALC_FIELD_DIFF_Y);
      dim3 blocks(nblocks(width, threads.x), nblocks(height, threads.y));
      dim3 blocksUV(nblocks(widthUV, threads.x), nblocks(heightUV, threads.y));
      kl_analyze_diff << <blocks, threads >> >(resultY, src0Y, src1Y, width, height, pitchY);
      DEBUG_SYNC;
      kl_analyze_diff << <blocksUV, threads >> >(resultUV, src0U, src1U, widthUV, heightUV, pitchUV);
      DEBUG_SYNC;
      kl_analyze_diff << <blocksUV, threads >> >(resultUV, src0V, src1V, widthUV, heightUV, pitchUV);
      DEBUG_SYNC;
    }
    else {
      cpu_analyze_diff(resultY, src0Y, src1Y, width, height, pitchY);
      cpu_analyze_diff(resultUV, src0U, src1U, widthUV, heightUV, pitchUV);
      cpu_analyze_diff(resultUV, src0V, src1V, widthUV, heightUV, pitchUV);
    }
  }

  PVideoFrame GetFrameT(int n, PNeoEnv env)
  {
    Frame noise0 = noiseclip->GetFrame(2 * n + 0, env);
    Frame noise1 = noiseclip->GetFrame(2 * n + 1, env);
    Frame noise2 = noiseclip->GetFrame(2 * n + 2, env);

    Frame f0padded;
    Frame f1padded;

    if (superclip) {
      f0padded = Frame(superclip->GetFrame(n, env), VPAD);
      f1padded = Frame(superclip->GetFrame(n + 1, env), VPAD);
    }
    else {
      Frame f0 = child->GetFrame(n, env);
      Frame f1 = child->GetFrame(n + 1, env);
      f0padded = Frame(env->NewVideoFrame(padvi), VPAD);
      f1padded = Frame(env->NewVideoFrame(padvi), VPAD);
      CopyFrame<uint8_t>(f0, f0padded, env);
      PadFrame<uint8_t>(f0padded, env);
      CopyFrame<uint8_t>(f1, f1padded, env);
      PadFrame<uint8_t>(f1padded, env);
    }

    Frame dst = env->NewVideoFrame(vi);

    NoiseResult* result = dst.GetWritePtr<NoiseResult>();

    InitAnalyze((uint64_t*)result, env);
    AnalyzeNoise(&result[0].noise0, &result[1].noise0, noise0, noise1, noise2, env);
    AnalyzeDiff(&result[0].diff0, &result[1].diff0, f0padded, f1padded, env);

    return dst.frame;
  }
public:
  KAnalyzeNoise(PClip src, PClip noise, PClip super, IScriptEnvironment* env)
    : KFMFilterBase(src)
    , noiseclip(noise)
    , srcvi(vi)
    , padvi(vi)
    , superclip(super)
  {
    if (srcvi.width & 3) env->ThrowError("[KAnalyzeNoise]: width must be multiple of 4");
    if (srcvi.height & 3) env->ThrowError("[KAnalyzeNoise]: height must be multiple of 4");

    padvi.height += VPAD * 2;

    int out_bytes = sizeof(NoiseResult) * 2;
    vi.pixel_type = VideoInfo::CS_BGR32;
    vi.width = 16;
    vi.height = nblocks(out_bytes, vi.width * 4);

    VideoInfo noisevi = noiseclip->GetVideoInfo();
    meta.srcw = srcvi.width;
    meta.srch = srcvi.height;
    meta.srcUVw = srcvi.width >> srcvi.GetPlaneWidthSubsampling(PLANAR_U);
    meta.srcUVh = srcvi.height >> srcvi.GetPlaneHeightSubsampling(PLANAR_U);
    meta.noisew = noisevi.width;
    meta.noiseh = noisevi.height;
    meta.noiseUVw = noisevi.width >> noisevi.GetPlaneWidthSubsampling(PLANAR_U);
    meta.noiseUVh = noisevi.height >> noisevi.GetPlaneHeightSubsampling(PLANAR_U);
    UCFNoiseMeta::SetParam(vi, &meta);
  }

  PVideoFrame __stdcall GetFrame(int n, IScriptEnvironment* env_)
  {
    PNeoEnv env = env_;

    int pixelSize = vi.ComponentSize();
    switch (pixelSize) {
    case 1:
      return GetFrameT(n, env);
      //case 2:
      //  dst = InternalGetFrame<uint16_t>(n60, fmframe, frameType, env);
      //  break;
    default:
      env->ThrowError("[KAnalyzeNoise] Unsupported pixel format");
      break;
    }

    return PVideoFrame();
  }

  static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
  {
    return new KAnalyzeNoise(
      args[0].AsClip(),       // src
      args[1].AsClip(),       // noise
      args[2].AsClip(),       // super
      env
    );
  }
};

enum DECOMBE_UCF_RESULT {
  DECOMBE_UCF_CLEAN_1, // 1次判定で綺麗なフレームと判定
  DECOMBE_UCF_CLEAN_2, // ノイズ判定で綺麗なフレームと判定
  DECOMBE_UCF_USE_0,   // 1番目のフィールドを使うべき
  DECOMBE_UCF_USE_1,   // 2番目のフィールドを使うべき
  DECOMBE_UCF_NOISY,   // どっちも汚い
};

struct DecombeUCFResult {
  DECOMBE_UCF_RESULT flag;
  std::string message;
};

struct DecombeUCFThreshScore {
  double y1, y2, y3, y4, y5;
  double x1, x2, x3, x4, x5;

  double calc(double x) const
  {
    return (x < x1) ? y1
      : (x < x2) ? ((y2 - y1)*x + x2*y1 - x1*y2) / (x2 - x1)
      : (x < x3) ? ((y3 - y2)*x + x3*y2 - x2*y3) / (x3 - x2)
      : (x < x4) ? ((y4 - y3)*x + x4*y3 - x3*y4) / (x4 - x3)
      : (x < x5) ? ((y5 - y4)*x + x5*y4 - x4*y5) / (x5 - x4)
      : y5;
  }
};

static DecombeUCFThreshScore THRESH_SCORE_PARAM_TABLE[] = {
  {}, // 0（使われない）
  { 13,17,17,20,50,20,28,32,37,50 }, // 1
  { 14,18,20,40,50,19,28,36,42,50 },
  { 15,19,21,43,63,20,28,36,41,53 },
  { 15,20,23,43,63,20,28,36,41,53 },
  { 15,20,23,45,63,20,28,36,41,50 }, // 5(default)
  { 15,21,23,45,63,20,28,36,41,50 },
  { 15,22,24,45,63,20,28,35,41,50 },
  { 17,25,28,47,64,20,28,33,41,48 },
  { 20,32,38,52,66,21,30,36,40,48 },
  { 22,37,44,52,66,22,32,35,40,48 }, // 10
};

#define DecombeUCF_PARAM_STR "[chroma]i[fd_thresh]f[th_mode]i[off_t]f[off_b]f" \
    "[namax_thresh]f[namax_diff]f[nrt1y]f[nrt2y]f[nrt2x]f[nrw]f[show]b" \
    "[y1]f[y2]f[y3]f[y4]f[y5]f[x1]f[x2]f[x3]f[x4]f[x5]f"

struct DecombeUCFParam {
  int chroma;       // [0-2] #(0:Y),(1:UV),(2:YUV) for noise detection
  double fd_thresh;    // [0-] #threshold of FieldDiff #fd_thresh = FieldDiff * 100 / (Width * Height)

  // threshold
  int th_mode;      // [1-2:debug][3-7:normal][8-10:restricted] #preset of diff threshold. you can also specify threshold by x1-x5 y1-y5(need th_mode=0).
  double off_t;        // offset for diff threshold of top field (first field, top,diff<0)
  double off_b;        // offset for diff threshold of bottom field (second field, botom, 0<diff)

  // reverse (chroma=0のみで機能。ノイズ量の絶対値が多過ぎる場合、映像効果と考えノイズの大きいフィールドを残す(小さいほうはブロックノイズによる平坦化))
  int namax_thresh; // 82 #MX:90 #[0-256] #disabled with chroma=1 #upper limit of max noise for Noise detaction (75-80-83)
  int namax_diff;   // 30-40 #disabled with chroma=1  #If average noise >= namax_thresh,  use namax_diff as diff threshold.

  // NR
  double nrt1y;        // 28-29-30 #threshold for nr
  double nrt2y;        // 36-36.5-37 #exclusion range
  double nrt2x;        // 53-54-55 #exclusion range
  double nrw;          // 1-2 #diff weight for nr threshold

  bool show;

  DecombeUCFThreshScore th_score;
};

static DecombeUCFParam MakeParam(AVSValue args, int base, PNeoEnv env)
{
  DecombeUCFParam param = {
    args[base + 0].AsInt(1),      // chroma
    args[base + 1].AsFloat(128),  // fd_thresh
    args[base + 2].AsInt(0),      // th_mode
    args[base + 3].AsFloat(0),    // off_t
    args[base + 4].AsFloat(0),    // off_b
    args[base + 5].AsInt(82),     // namax_thresh
    args[base + 6].AsInt(38),     // namax_diff
    args[base + 7].AsFloat(28),   // nrt1y
    args[base + 8].AsFloat(36),   // nrt2y
    args[base + 9].AsFloat(53.5), // nrt2x
    args[base + 10].AsFloat(2),    // nrw
    args[base + 11].AsBool(false)  // show
  };

  // check param
  if (param.chroma < 0 || param.chroma > 2) {
    env->ThrowError("[DecombeUCFParam]: chroma must be 0-2");
  }
  if (param.fd_thresh < 0) {
    env->ThrowError("[DecombeUCFParam]: fd_thresh must be >=0");
  }
  if (param.th_mode < 0 || param.th_mode > 10) {
    env->ThrowError("[DecombeUCFParam]: th_mode must be 0-10");
  }
  if (param.namax_thresh < 0 || param.namax_thresh > 256) {
    env->ThrowError("[DecombeUCFParam]: namax_thresh should be in range 0-256");
  }

  base += 12;
  if (param.th_mode == 0) {
    DecombeUCFThreshScore* def = &THRESH_SCORE_PARAM_TABLE[5];
    DecombeUCFThreshScore th_score = {
      (float)args[base + 0].AsFloat((float)def->y1),
      (float)args[base + 1].AsFloat((float)def->y2),
      (float)args[base + 2].AsFloat((float)def->y3),
      (float)args[base + 3].AsFloat((float)def->y4),
      (float)args[base + 4].AsFloat((float)def->y5),
      (float)args[base + 5].AsFloat((float)def->x1),
      (float)args[base + 6].AsFloat((float)def->x2),
      (float)args[base + 7].AsFloat((float)def->x3),
      (float)args[base + 8].AsFloat((float)def->x4),
      (float)args[base + 9].AsFloat((float)def->x5)
    };
    param.th_score = th_score;
  }
  else {
    param.th_score = THRESH_SCORE_PARAM_TABLE[param.th_mode];
  }

  return param;
}

DECOMBE_UCF_RESULT CalcDecombeUCF(
  const UCFNoiseMeta* meta,
  const DecombeUCFParam* param,
  const NoiseResult* result0, // 1フレーム目
  const NoiseResult* result1, // 2フレーム目(second=falseならnullptr可)
  bool second,          // 
  std::string* message) // デバッグメッセージ
{
  double pixels = meta->srcw * meta->srch;
  //double pixelsUV = meta->srcUVw * meta->srcUVh;
  double noisepixels = meta->noisew * meta->noiseh;
  double noisepixelsUV = meta->noiseUVw * meta->noiseUVh * 2;

  // 1次判定フィールド差分
  double field_diff = (second 
    ? (result0[0].diff1 + result0[1].diff1)
    : (result0[0].diff0 + result0[1].diff0)) / (6 * pixels) * 100;

  // 絶対ノイズ量
  double noise_t_y = (second ? result0[0].noise1 : result0[0].noise0) / noisepixels;
  double noise_t_uv = (second ? result0[1].noise1 : result0[1].noise0) / noisepixelsUV;
  double noise_b_y = (second ? result1[0].noise0 : result0[0].noise1) / noisepixels;
  double noise_b_uv = (second ? result1[1].noise0 : result0[1].noise1) / noisepixelsUV;
  // 絶対ノイズ-平均(reverseで利用)
  double navg1_y = (noise_t_y + noise_b_y) / 2;
  double navg1_uv = (noise_t_uv + noise_b_uv) / 2;
  // 相対ノイズ-平均 [comp t,b](diff計算で利用)
  double navg2_y = (second ? result0[0].noiseR1 : result0[0].noiseR0) / noisepixels / 2;
  double navg2_uv = (second ? result0[1].noiseR1 : result0[1].noiseR0) / noisepixelsUV / 2;
  // 絶対ノイズ-符号付差分(diff計算で利用)
  double diff1_y = noise_t_y - noise_b_y;
  double diff1_uv = noise_t_uv - noise_b_uv;

  double diff1;     // 絶対ノイズ - 符号付差分
  double navg1;     // 絶対ノイズ平均(総ノイズ量判定用, 色差の細かい模様は滅多に見ない)
  double navg1_d;   // debug用
  double navg2;     // 相対ノイズ - 平均

  if (param->chroma == 0) {
    // Y
    diff1 = diff1_y;
    navg1_d = navg1 = navg1_y;
    navg2 = navg2_y;
  }
  else if (param->chroma == 1) {
    // UV
    diff1 = diff1_uv;
    navg1 = -1;
    navg1_d = navg1_uv;
    navg2 = navg2_uv;
  }
  else { // param->chroma == 2
    // YUV
    diff1 = (diff1_y + diff1_uv) / 2;
    navg1_d = navg1 = (navg1_y + navg1_uv) / 2;
    navg2 = (navg2_y + navg2_uv) / 2;
  }

  double absdiff1 = std::abs(diff1);
  double nmin1 = navg2 - absdiff1 / 2;
  double nmin = (nmin1 < 7) ? nmin1 * 4 : nmin1 + 21;
  double nmax = navg2 + absdiff1*param->nrw;
  double off_thresh = (diff1 < 0) ? param->off_t : param->off_b;
  double min_thresh = (navg1 < param->namax_thresh) 
    ? param->th_score.calc(nmin) + off_thresh 
    : param->namax_diff + off_thresh;
    // 符号付補正差分
  double diff = absdiff1 < 1.8 ? diff1 * 10
    : absdiff1 < 5 ? diff1 * 5 + (diff1 / absdiff1) * 9
    : absdiff1 < 10 ? diff1 * 2 + (diff1 / absdiff1) * 24
    : diff1 + (diff1 / absdiff1) * 34;

  DECOMBE_UCF_RESULT result;
  if (std::abs(diff) < min_thresh) {
    result = ((nmax < param->nrt1y) || (param->nrt2x < navg1_d && nmax < param->nrt2y))
      ? DECOMBE_UCF_CLEAN_2 : DECOMBE_UCF_NOISY;
  }
  else if (navg1 < param->namax_thresh) {
    result = (diff < 0) ? DECOMBE_UCF_USE_0 : DECOMBE_UCF_USE_1;
  }
  else {
    result = (diff < 0) ? DECOMBE_UCF_USE_1 : DECOMBE_UCF_USE_0;
  }

  if (message) {
    char debug1_n_t[64];
    char debug1_n_b[64];
    if (param->chroma == 0) {
      sprintf_s(debug1_n_t, " Noise  [Y : %7f]", noise_t_y);
      sprintf_s(debug1_n_b, " Noise  [Y : %7f]", noise_b_y);
    }
    else if (param->chroma == 1) {
      sprintf_s(debug1_n_t, " Noise  [UV: %7f]", noise_t_uv);
      sprintf_s(debug1_n_b, " Noise  [UV: %7f]", noise_b_uv);
    }
    else {
      sprintf_s(debug1_n_t, " Noise  [Y : %7f] [UV: %7f]", noise_t_y, noise_t_uv);
      sprintf_s(debug1_n_b, " Noise  [Y : %7f] [UV: %7f]", noise_b_y, noise_b_uv);
    }
    char reschar = '-';
    char fdeq = '>';
    char noiseeq = '<';
    const char* field = "";
    if (field_diff < param->fd_thresh) {
      reschar = 'A';
      field = "notbob";
      fdeq = '<';
    }
    else if (result == DECOMBE_UCF_CLEAN_2 || result == DECOMBE_UCF_NOISY) {
      reschar = 'B';
      field = "notbob";
      if (result == DECOMBE_UCF_NOISY) {
        noiseeq = '>';
      }
    }
    else {
      reschar = 'C';
      field = (result == DECOMBE_UCF_USE_0) ? "First" : "Second";
    }
    const char* extra = "";
    if (result == DECOMBE_UCF_NOISY) {
      extra = "NR";
    }
    else if (field_diff < param->fd_thresh && result != DECOMBE_UCF_CLEAN_2) {
      extra = "NOT CLEAN ???";
    }
    else if (navg1 >= param->namax_thresh) {
      extra = "Reversed";
    }
    char buf[512];
    sprintf_s(buf,
      "[%c] %-6s  //  Fdiff =  %8f (FieldDiff %c %8f)\n"
      "                diff =  %8f  (NoiseDiff %c %.2f)\n"
      " Noise // First %s / Second %s\n"
      " navg1 : %.2f / nmin : %.2f / diff1 : %.3f / nrt : %.1f\n"
      "%s\n",
      reschar, field, field_diff, fdeq, param->fd_thresh,
      diff, noiseeq, min_thresh,
      debug1_n_t, debug1_n_b,
      navg1_d, nmin, diff1, nmax,
      extra);
    *message += buf;
  }

  return (field_diff < param->fd_thresh) ? DECOMBE_UCF_CLEAN_1 : result;
}


class KDecombeUCF : public KFMFilterBase
{
  PClip fmclip;
  PClip bobclip;
  PClip noiseclip;
  PClip nrclip;

  const UCFNoiseMeta* meta;
  DecombeUCFParam param;
  PulldownPatterns patterns;

public:
  KDecombeUCF(PClip clip24, PClip fmclip, PClip noiseclip, PClip bobclip, PClip nrclip, DecombeUCFParam param, IScriptEnvironment* env)
    : KFMFilterBase(clip24)
    , fmclip(fmclip)
    , noiseclip(noiseclip)
    , bobclip(bobclip)
    , nrclip(nrclip)
    , meta(UCFNoiseMeta::GetParam(noiseclip->GetVideoInfo(), env))
    , param(param)
  {
    if (srcvi.width & 3) env->ThrowError("[KDecombeUCF]: width must be multiple of 4");
    if (srcvi.height & 3) env->ThrowError("[KDecombeUCF]: height must be multiple of 4");
  }

  PVideoFrame __stdcall GetFrame(int n24, IScriptEnvironment* env_)
  {
    PNeoEnv env = env_;
    PDevice cpu_device = env->GetDevice(DEV_TYPE_CPU, 0);

    int cycleIndex = n24 / 4;
    Frame fmframe = env->GetFrame(fmclip, cycleIndex, cpu_device);
    int pattern = (int)fmframe.GetProperty("KFM_Pattern")->GetInt();

    // 24pフレーム番号を取得
    Frame24Info frameInfo = patterns.GetFrame24(pattern, n24);
    std::string message;

    int useField = -1;
    bool isDurty = false;
    for (int i = 0; i < frameInfo.numFields - 1; ++i) {
      int n60 = frameInfo.cycleIndex * 10 + frameInfo.fieldStartIndex + i;
      Frame f0 = env->GetFrame(noiseclip, n60 / 2 + 0, cpu_device);
      Frame f1 = env->GetFrame(noiseclip, n60 / 2 + 1, cpu_device);
      const NoiseResult* result0 = f0.GetReadPtr<NoiseResult>();
      const NoiseResult* result1 = f1.GetReadPtr<NoiseResult>();

      std::string* mesptr = nullptr;
      if (param.show) {
        char buf[64];
        sprintf_s(buf, "24p Field: %d-%d(0-%d)\n", i, i+1, frameInfo.numFields - 1);
        message += buf;
        mesptr = &message;
      }

      auto result = CalcDecombeUCF(meta, &param, result0, result1, (n60 & 1) != 0, mesptr);
      
      if (result == DECOMBE_UCF_USE_0) useField = i + 0;
      if (result == DECOMBE_UCF_USE_1) useField = i + 1;
      if (result == DECOMBE_UCF_NOISY) isDurty = true;

      if (useField != -1 && !param.show) {
        // 1つ見つけたらもう終わり
        break;
      }
    }

    if (param.show) {
      // messageを書いて返す
      Frame frame = child->GetFrame(n24, env);
      DrawText<uint8_t>(frame.frame, vi.BitsPerComponent(), 0, 0, message, env);
      return frame.frame;
    }
    if (useField != -1) {
      // 綺麗なフィールドに置き換える
      int n60 = frameInfo.cycleIndex * 10 + frameInfo.fieldStartIndex + useField;
      return bobclip->GetFrame(n60, env);
    }
    if (isDurty && nrclip) {
      nrclip->GetFrame(n24, env);
    }
    return child->GetFrame(n24, env);
  }

  static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
  {
    return new KDecombeUCF(
      args[0].AsClip(),       // clip24
      args[1].AsClip(),       // fmclip
      args[2].AsClip(),       // noise
      args[3].AsClip(),       // bobc
      args[4].AsClip(),       // nr
      MakeParam(args, 5, env), // param
      env
    );
  }
};

class KDecombeUCF24 : public KFMFilterBase
{
  PClip bobclip;
  PClip noiseclip;
  PClip nrclip;

  const UCFNoiseMeta* meta;
  DecombeUCFParam param;
  PulldownPatterns patterns;

public:
  KDecombeUCF24(PClip clip24, PClip noiseclip, PClip bobclip, PClip nrclip, DecombeUCFParam param, IScriptEnvironment* env)
    : KFMFilterBase(clip24)
    , noiseclip(noiseclip)
    , bobclip(bobclip)
    , nrclip(nrclip)
    , meta(UCFNoiseMeta::GetParam(noiseclip->GetVideoInfo(), env))
    , param(param)
  {
    if (srcvi.width & 3) env->ThrowError("[KDecombeUCF24]: width must be multiple of 4");
    if (srcvi.height & 3) env->ThrowError("[KDecombeUCF24]: height must be multiple of 4");
  }

  PVideoFrame __stdcall GetFrame(int n24, IScriptEnvironment* env_)
  {
    PNeoEnv env = env_;
    PDevice cpu_device = env->GetDevice(DEV_TYPE_CPU, 0);

    Frame f0 = env->GetFrame(noiseclip, n24, cpu_device);
    const NoiseResult* result0 = f0.GetReadPtr<NoiseResult>();

    std::string message;
    auto result = CalcDecombeUCF(meta, &param,
      result0, nullptr, false, param.show ? &message : nullptr);

    if (param.show) {
      // messageを書いて返す
      Frame frame = child->GetFrame(n24, env);
      DrawText<uint8_t>(frame.frame, vi.BitsPerComponent(), 0, 0, message, env);
      return frame.frame;
    }

    if (result == DECOMBE_UCF_USE_0) {
      return bobclip->GetFrame(n24 * 2 + 0, env);
    }
    if (result == DECOMBE_UCF_USE_1) {
      return bobclip->GetFrame(n24 * 2 + 1, env);
    }
    if (result == DECOMBE_UCF_NOISY && nrclip) {
      return nrclip->GetFrame(n24, env);
    }
    return child->GetFrame(n24, env);
  }

  static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
  {
    return new KDecombeUCF24(
      args[0].AsClip(),       // clip24
      args[1].AsClip(),       // noiseclip
      args[2].AsClip(),       // bobclip
      args[3].Defined() ? args[3].AsClip() : nullptr,       // nrclip
      MakeParam(args, 4, env), // param
      env
    );
  }
};

void AddFuncUCF(IScriptEnvironment* env)
{
  env->AddFunction("KCFieldDiff", "c[nt]f[chroma]b", KFieldDiff::CFunc, 0);
  env->AddFunction("KCFrameDiffDup", "c[chroma]b[blksize]i", KFrameDiffDup::CFunc, 0);

  env->AddFunction("KNoiseClip", "cc[nmin_y]i[range_y]i[nmin_uv]i[range_uv]i", KNoiseClip::Create, 0);
  env->AddFunction("KAnalyzeNoise", "cc[super]c", KAnalyzeNoise::Create, 0);
  env->AddFunction("KDecombeUCF", "cccc[nr]c" DecombeUCF_PARAM_STR, KDecombeUCF::Create, 0);
  env->AddFunction("KDecombeUCF24", "ccc[nr]c" DecombeUCF_PARAM_STR, KDecombeUCF24::Create, 0);
}
