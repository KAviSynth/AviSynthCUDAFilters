#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>
#include "avisynth.h"

#include <algorithm>
#include <memory>

#include <cuda_runtime_api.h>
#include <cuda_device_runtime_api.h>

#include "CommonFunctions.h"
#include "KDeintKernel.h"

/////////////////////////////////////////////////////////////////////////////
// COPY
/////////////////////////////////////////////////////////////////////////////

template <typename pixel_t>
__global__ void kl_copy(
  pixel_t* dst, int dst_pitch, const pixel_t* src, int src_pitch, int width, int height)
{
  int x = threadIdx.x + blockIdx.x * blockDim.x;
  int y = threadIdx.y + blockIdx.y * blockDim.y;

  if (x < width && y < height) {
    dst[x + y * dst_pitch] = src[x + y * src_pitch];
  }
}

template <typename pixel_t>
void KDeintKernel::Copy(
  pixel_t* dst, int dst_pitch, const pixel_t* src, int src_pitch, int width, int height)
{
  dim3 threads(32, 16);
  dim3 blocks(nblocks(width, threads.x), nblocks(height, threads.y));
  kl_copy<pixel_t> << <blocks, threads, 0, stream >> > (
    dst, dst_pitch, src, src_pitch, width, height);
  DebugSync();
}

template void KDeintKernel::Copy<uint8_t>(
  uint8_t* dst, int dst_pitch, const uint8_t* src, int src_pitch, int width, int height);
template void KDeintKernel::Copy<uint16_t>(
  uint16_t* dst, int dst_pitch, const uint16_t* src, int src_pitch, int width, int height);
template void KDeintKernel::Copy<int16_t>(
  int16_t* dst, int dst_pitch, const int16_t* src, int src_pitch, int width, int height);
template void KDeintKernel::Copy<int32_t>(
  int32_t* dst, int dst_pitch, const int32_t* src, int src_pitch, int width, int height);


/////////////////////////////////////////////////////////////////////////////
// PadFrame
/////////////////////////////////////////////////////////////////////////////

// width �� Pad ���܂܂Ȃ�����
// block(2, -), threads(hPad, -)
template <typename pixel_t>
__global__ void kl_pad_frame_h(pixel_t* ptr, int pitch, int hPad, int width, int height)
{
  bool isLeft = (blockIdx.x == 0);
  int x = threadIdx.x;
  int y = threadIdx.y + blockIdx.y * blockDim.y;

  if (y < height) {
    if (isLeft) {
      ptr[x + y * pitch] = ptr[hPad + y * pitch];
    }
    else {
      ptr[(hPad + width + x) + y * pitch] = ptr[(hPad + width) + y * pitch];
    }
  }
}

// height �� Pad ���܂܂Ȃ�����
// block(-, 2), threads(-, vPad)
template <typename pixel_t>
__global__ void kl_pad_frame_v(pixel_t* ptr, int pitch, int vPad, int width, int height)
{
  bool isTop = (blockIdx.y == 0);
  int x = threadIdx.x + blockIdx.x * blockDim.x;
  int y = threadIdx.y;

  if (x < width) {
    if (isTop) {
      ptr[x + y * pitch] = ptr[x + vPad * pitch];
    }
    else {
      ptr[x + (vPad + height + y) * pitch] = ptr[x + (vPad + height) * pitch];
    }
  }
}

template<typename pixel_t>
void KDeintKernel::PadFrame(pixel_t *ptr, int pitch, int hPad, int vPad, int width, int height)
{
  { // H����
    dim3 threads(hPad, 32);
    dim3 blocks(2, nblocks(height, threads.y));
    kl_pad_frame_h<pixel_t> << <blocks, threads, 0, stream >> > (
      ptr + vPad * pitch, pitch, hPad, width, height);
    DebugSync();
  }
  { // V�����i���ł�Pad���ꂽH���������܂ށj
    dim3 threads(32, vPad);
    dim3 blocks(nblocks(width + hPad * 2, threads.x), 2);
    kl_pad_frame_v<pixel_t> << <blocks, threads, 0, stream >> > (
      ptr, pitch, vPad, width + hPad * 2, height);
    DebugSync();
  }
}

template void KDeintKernel::PadFrame<uint8_t>(
  uint8_t *ptr, int pitch, int hPad, int vPad, int width, int height);
template void KDeintKernel::PadFrame<uint16_t>(
  uint16_t *ptr, int pitch, int hPad, int vPad, int width, int height);


/////////////////////////////////////////////////////////////////////////////
// Wiener
/////////////////////////////////////////////////////////////////////////////

// so called Wiener interpolation. (sharp, similar to Lanczos ?)
// invarint simplified, 6 taps. Weights: (1, -5, 20, 20, -5, 1)/32 - added by Fizick
template<typename pixel_t>
__global__ void kl_vertical_wiener(pixel_t *pDst, const pixel_t *pSrc, int nDstPitch,
  int nSrcPitch, int nWidth, int nHeight, int max_pixel_value)
{
  int x = threadIdx.x + blockIdx.x * blockDim.x;
  int y = threadIdx.y + blockIdx.y * blockDim.y;

  if (x < nWidth) {
    if (y < 2) {
      pDst[x + y * nDstPitch] = (pSrc[x + y * nSrcPitch] + pSrc[x + (y + 1) * nSrcPitch] + 1) >> 1;
    }
    else if (y < nHeight - 4) {
      pDst[x + y * nDstPitch] = min(max_pixel_value, max(0,
        (pSrc[x + (y - 2) * nSrcPitch]
          + (-(pSrc[x + (y - 1) * nSrcPitch]) + (pSrc[x + y * nSrcPitch] << 2) +
          (pSrc[x + (y + 1) * nSrcPitch] << 2) - (pSrc[x + (y + 2) * nSrcPitch])) * 5
          + (pSrc[x + (y + 3) * nSrcPitch]) + 16) >> 5));
    }
    else if (y < nHeight - 1) {
      pDst[x + y * nDstPitch] = (pSrc[x + y * nSrcPitch] + pSrc[x + (y + 1) * nSrcPitch] + 1) >> 1;
    }
    else if (y < nHeight) {
      // last row
      pDst[x + y * nDstPitch] = pSrc[x + y * nSrcPitch];
    }
  }
}

template<typename pixel_t>
void KDeintKernel::VerticalWiener(
  pixel_t *pDst, const pixel_t *pSrc, int nDstPitch,
  int nSrcPitch, int nWidth, int nHeight, int bits_per_pixel)
{
  const int max_pixel_value = sizeof(pixel_t) == 1 ? 255 : (1 << bits_per_pixel) - 1;

  dim3 threads(32, 16);
  dim3 blocks(nblocks(nWidth, threads.x), nblocks(nHeight, threads.y));
  kl_vertical_wiener<pixel_t> << <blocks, threads, 0, stream >> > (
    pDst, pSrc, nDstPitch, nSrcPitch, nWidth, nHeight, max_pixel_value);
  DebugSync();
}

template<typename pixel_t>
__global__ void kl_horizontal_wiener(pixel_t *pDst, const pixel_t *pSrc, int nDstPitch,
  int nSrcPitch, int nWidth, int nHeight, int max_pixel_value)
{
  int x = threadIdx.x + blockIdx.x * blockDim.x;
  int y = threadIdx.y + blockIdx.y * blockDim.y;

  if (y < nHeight) {
    if (x < 2) {
      pDst[x + y * nDstPitch] = (pSrc[x + y * nSrcPitch] + pSrc[(x + 1) + y * nSrcPitch] + 1) >> 1;
    }
    else if (x < nWidth - 4) {
      pDst[x + y * nDstPitch] = min(max_pixel_value, max(0,
        (pSrc[(x - 2) + y * nSrcPitch]
          + (-(pSrc[(x - 1) + y * nSrcPitch]) + (pSrc[x + y * nSrcPitch] << 2) +
          (pSrc[(x + 1) + y * nSrcPitch] << 2) - (pSrc[(x + 2) + y * nSrcPitch])) * 5
          + (pSrc[(x + 3) + y * nSrcPitch]) + 16) >> 5));
    }
    else if (x < nWidth - 1) {
      pDst[x + y * nDstPitch] = (pSrc[x + y * nSrcPitch] + pSrc[(x + 1) + y * nSrcPitch] + 1) >> 1;
    }
    else if (x < nWidth) {
      // last column
      pDst[x + y * nDstPitch] = pSrc[x + y * nSrcPitch];
    }
  }
}

template<typename pixel_t>
void KDeintKernel::HorizontalWiener(
  pixel_t *pDst, const pixel_t *pSrc, int nDstPitch,
  int nSrcPitch, int nWidth, int nHeight, int bits_per_pixel)
{
  const int max_pixel_value = sizeof(pixel_t) == 1 ? 255 : (1 << bits_per_pixel) - 1;

  dim3 threads(32, 16);
  dim3 blocks(nblocks(nWidth, threads.x), nblocks(nHeight, threads.y));
  kl_horizontal_wiener<pixel_t> << <blocks, threads, 0, stream >> > (
    pDst, pSrc, nDstPitch, nSrcPitch, nWidth, nHeight, max_pixel_value);
  DebugSync();
}


template void KDeintKernel::VerticalWiener<uint8_t>(
  uint8_t *pDst, const uint8_t *pSrc, int nDstPitch,
  int nSrcPitch, int nWidth, int nHeight, int bits_per_pixel);
template void KDeintKernel::VerticalWiener<uint16_t>(
  uint16_t *pDst, const uint16_t *pSrc, int nDstPitch,
  int nSrcPitch, int nWidth, int nHeight, int bits_per_pixel);
template void KDeintKernel::HorizontalWiener<uint8_t>(
  uint8_t *pDst, const uint8_t *pSrc, int nDstPitch,
  int nSrcPitch, int nWidth, int nHeight, int bits_per_pixel);
template void KDeintKernel::HorizontalWiener<uint16_t>(
  uint16_t *pDst, const uint16_t *pSrc, int nDstPitch,
  int nSrcPitch, int nWidth, int nHeight, int bits_per_pixel);


/////////////////////////////////////////////////////////////////////////////
// RB2BilinearFilter
/////////////////////////////////////////////////////////////////////////////

enum {
  RB2B_BILINEAR_W = 32,
  RB2B_BILINEAR_H = 16,
};

// BilinearFiltered with 1/8, 3/8, 3/8, 1/8 filter for smoothing and anti-aliasing - Fizick
// threads=(RB2B_BILINEAR_W,RB2B_BILINEAR_H)
// nblocks=(nblocks(nWidth*2, RB2B_BILINEAR_W - 2),nblocks(nHeight,RB2B_BILINEAR_H))
template<typename pixel_t>
__global__ void kl_RB2B_bilinear_filtered(
  pixel_t *pDst, const pixel_t *pSrc, int nDstPitch, int nSrcPitch, int nWidth, int nHeight)
{
  __shared__ pixel_t tmp[RB2B_BILINEAR_H][RB2B_BILINEAR_W];

  int tx = threadIdx.x;
  int ty = threadIdx.y;

  // Vertical�����s
  // Horizontal�ŎQ�Ƃ��邽�ߗ��[1�񂸂]���Ɏ��s
  int x = tx - 1 + blockIdx.x * (RB2B_BILINEAR_W - 2);
  int y = ty + blockIdx.y * RB2B_BILINEAR_H;
  int y2 = y * 2;

  if (x >= 0 && x < nWidth * 2) {
    if (y < 1) {
      tmp[ty][tx] = (pSrc[x + y2 * nSrcPitch] + pSrc[x + (y2 + 1) * nSrcPitch] + 1) / 2;
    }
    else if (y < nHeight - 1) {
      tmp[ty][tx] = (pSrc[x + (y2 - 1) * nSrcPitch]
        + pSrc[x + y2 * nSrcPitch] * 3
        + pSrc[x + (y2 + 1) * nSrcPitch] * 3
        + pSrc[x + (y2 + 2) * nSrcPitch] + 4) / 8;
    }
    else if (y < nHeight) {
      tmp[ty][tx] = (pSrc[x + y2 * nSrcPitch] + pSrc[x + (y2 + 1) * nSrcPitch] + 1) / 2;
    }
  }

  __syncthreads();

  // Horizontal�����s
  x = tx + blockIdx.x * ((RB2B_BILINEAR_W - 2) / 2);
  int tx2 = tx * 2;

  if (tx < ((RB2B_BILINEAR_W - 2) / 2) && y < nHeight) {
    // tmp��[0][1]�����_�ł��邱�Ƃɒ���
    if (x < 1) {
      pDst[x + y * nDstPitch] = (tmp[ty][tx2 + 1] + tmp[ty][tx2 + 2] + 1) / 2;
    }
    else if (x < nWidth - 1) {
      pDst[x + y * nDstPitch] = (tmp[ty][tx2]
        + tmp[ty][tx2 + 1] * 3
        + tmp[ty][tx2 + 2] * 3
        + tmp[ty][tx2 + 3] + 4) / 8;
    }
    else if (x < nWidth) {
      pDst[x + y * nDstPitch] = (tmp[ty][tx2 + 1] + tmp[ty][tx2 + 2] + 1) / 2;
    }
  }
}

template<typename pixel_t>
void KDeintKernel::RB2BilinearFiltered(
  pixel_t *pDst, const pixel_t *pSrc, int nDstPitch, int nSrcPitch, int nWidth, int nHeight)
{
  dim3 threads(RB2B_BILINEAR_W, RB2B_BILINEAR_H);
  dim3 blocks(nblocks(nWidth*2, RB2B_BILINEAR_W - 2), nblocks(nHeight, RB2B_BILINEAR_H));
  kl_RB2B_bilinear_filtered<pixel_t> << <blocks, threads, 0, stream >> > (
    pDst, pSrc, nDstPitch, nSrcPitch, nWidth, nHeight);
  DebugSync();
}

template void KDeintKernel::RB2BilinearFiltered<uint8_t>(
  uint8_t *pDst, const uint8_t *pSrc, int nDstPitch, int nSrcPitch, int nWidth, int nHeight);
template void KDeintKernel::RB2BilinearFiltered<uint16_t>(
  uint16_t *pDst, const uint16_t *pSrc, int nDstPitch, int nSrcPitch, int nWidth, int nHeight);



/////////////////////////////////////////////////////////////////////////////
// SearchMV
/////////////////////////////////////////////////////////////////////////////


typedef int sad_t; // ���float�ɂ���

enum {
  SRCH_DIMX = 128
};

struct SearchBlock {
  // [0-3]: nDxMax, nDyMax, nDxMin, nDyMin �iMax��Max-1�ɂ��Ă����j
  // [4-9]: Left predictor, Up predictor, bottom-right predictor(from coarse level)
  // �����ȂƂ���͍��Ȃ��悤�ɂ���i�Œ�ł��ǂꂩ�P�͗L���Ȃ̂Ŗ����Ȃ�Ƃ���͂��̃C���f�b�N�X�Ŗ��߂�j
  // [10-11]: predictor �� x, y
  int data[12];
  // [0-3]: penaltyZero, penaltyGlobal, 1(penaltyPredictor), penaltyNew
  // [4]: lambda
  sad_t dataf[5];
};

#define CLIP_RECT data
#define REF_VECTOR_INDEX (&data[4])
#define PRED_X data[10]
#define PRED_Y data[11]
#define PENALTIES dataf
#define PENALTY_NEW dataf[3]
#define LAMBDA dataf[4]

#define LARGE_COST INT_MAX

struct CostResult {
  sad_t cost;
  short2 xy;
};

__device__ void dev_clip_mv(short2& v, const int* rect)
{
  v.x = (v.x > rect[0]) ? rect[0] : (v.x < rect[2]) ? rect[2] : v.x;
  v.y = (v.y > rect[1]) ? rect[1] : (v.y < rect[3]) ? rect[3] : v.y;
}

__device__ bool dev_check_mv(int x, int y, const int* rect)
{
  return (x <= rect[0]) & (y <= rect[1]) & (x >= rect[2]) & (y >= rect[3]);
}

__device__ int dev_max(int a, int b, int c) {
  int ab = (a > b) ? a : b;
  return (ab > c) ? ab : c;
}

__device__ int dev_min(int a, int b, int c) {
  int ab = (a < b) ? a : b;
  return (ab < c) ? ab : c;
}

__device__ int dev_sq_norm(int ax, int ay, int bx, int by) {
  return (ax - bx) * (ax - bx) + (ay - by) * (ay - by);
}

// pRef �� �u���b�N�I�t�Z�b�g����\�߈ړ������Ă������|�C���^
// vx,vy �� �T�u�s�N�Z�����܂߂��x�N�g��
template <typename pixel_t, int NPEL>
__device__ const pixel_t* dev_get_ref_block(const pixel_t* pRef, int nPitch, int nImgPitch, int vx, int vy)
{
  if (NPEL != 1) {
    int sx = vx % NPEL;
    int sy = vy % NPEL;
    int si = sx + sy * NPEL;
    int x = vx / NPEL;
    int y = vy / NPEL;
    return &pRef[x + y * nPitch + si * nImgPitch];
  }
  else {
    return &pRef[vx + vy * nPitch];
  }
}

__device__ int dev_reduce_sad(int sad, int tid)
{
  // warp shuffle��reduce
  sad += __shfl_down(sad, 8);
  sad += __shfl_down(sad, 4);
  sad += __shfl_down(sad, 2);
  sad += __shfl_down(sad, 1);
  return sad;
}

template <typename pixel_t, int BLK_SIZE>
__device__ sad_t dev_calc_sad(
  int wi,
  const pixel_t* pSrcY, const pixel_t* pSrcU, const pixel_t* pSrcV,
  const pixel_t* pRefY, const pixel_t* pRefU, const pixel_t* pRefV,
  int nPitchY, int nPitchU, int nPitchV)
{
  int sad = 0;
  if (BLK_SIZE == 16) {
    // �u���b�N�T�C�Y���X���b�h���ƈ�v
    int yx = wi;
    for (int yy = 0; yy < BLK_SIZE; ++yy) { // 16�񃋁[�v
      sad = __sad(pSrcY[yx + yy * BLK_SIZE], pRefY[yx + yy * nPitchY], sad);
    }
    // UV��8x8
    int uvx = wi % 8;
    int uvy = wi / 8;
    for (int t = 0; t < 4; ++t, uvy += 2) { // 4�񃋁[�v
      sad = __sad(pSrcU[uvx + uvy * BLK_SIZE], pRefU[uvx + uvy * nPitchU], sad);
      sad = __sad(pSrcV[uvx + uvy * BLK_SIZE], pRefV[uvx + uvy * nPitchV], sad);
    }
  }
  else if (BLK_SIZE == 32) {
    // 32x32
    int yx = wi;
    for (int yy = 0; yy < BLK_SIZE; ++yy) { // 32�񃋁[�v
      sad = __sad(pSrcY[yx + yy * BLK_SIZE], pRefY[yx + yy * nPitchY], sad);
      sad = __sad(pSrcY[yx + 16 + yy * BLK_SIZE], pRefY[yx + 16 + yy * nPitchY], sad);
    }
    // �u���b�N�T�C�Y���X���b�h���ƈ�v
    int uvx = wi;
    for (int uvy = 0; uvy < BLK_SIZE; ++uvy) { // 16�񃋁[�v
      sad = __sad(pSrcU[uvx + uvy * BLK_SIZE], pRefU[uvx + uvy * nPitchU], sad);
      sad = __sad(pSrcV[uvx + uvy * BLK_SIZE], pRefV[uvx + uvy * nPitchV], sad);
    }
  }
  return dev_reduce_sad(sad, wi);
}

// MAX - (MAX/4) <= (���ʂ̌�) <= MAX �ł��邱��
// �X���b�h���� (���ʂ̌�) - MAX/2
template <int MAX>
__device__ void dev_reduce_result(CostResult* tmp_, int tid)
{
  volatile CostResult* tmp = (volatile CostResult*)tmp_;
  if(MAX >= 16) tmp[tid] = (tmp[tid].cost < tmp[tid + 8].cost) ? tmp[tid] : tmp[tid + 8];
  tmp[tid] = (tmp[tid].cost < tmp[tid + 4].cost) ? tmp[tid] : tmp[tid + 4];
  tmp[tid] = (tmp[tid].cost < tmp[tid + 2].cost) ? tmp[tid] : tmp[tid + 2];
  tmp[tid] = (tmp[tid].cost < tmp[tid + 1].cost) ? tmp[tid] : tmp[tid + 1];
}

// __syncthreads()���Ăяo���Ă���̂őS���ŌĂ�
template <typename pixel_t, int BLK_SIZE, int NPEL>
__device__ void dev_expanding_search_1(
  int tx, int wi, int bx, int cx, int cy,
  const int* data, const sad_t* dataf,
  CostResult& bestResult,
  const pixel_t* pSrcY, const pixel_t* pSrcU, const pixel_t* pSrcV,
  const pixel_t* __restrict__ pRefBY, const pixel_t* __restrict__ pRefBU, const pixel_t* __restrict__ pRefBV,
  int nPitchY, int nPitchU, int nPitchV,
  int nImgPitchY, int nImgPitchU, int nImgPitchV)
{
  int2 area[] = {
    { -1, -1 },
    { 0, -1 },
    { 1, -1 },
    { -1, 0 },
    { 1, 0 },
    { -1, 1 },
    { 0, 1 },
    { 1, 1 }
  };

  __shared__ bool isVectorOK[8];
  __shared__ CostResult result[8];
  __shared__ const pixel_t* pRefY[8];
  __shared__ const pixel_t* pRefU[8];
  __shared__ const pixel_t* pRefV[8];

  if (tx < 8) {
    int x = result[tx].xy.x = cx + area[tx].x;
    int y = result[tx].xy.y = cy + area[tx].y;
    bool ok = dev_check_mv(x, y, CLIP_RECT);
    int cost = (LAMBDA * dev_sq_norm(x, y, PRED_X, PRED_Y)) >> 8;

    // no additional SAD calculations if partial sum is already above minCost
    if (cost >= bestResult.cost) {
      ok = false;
    }

    isVectorOK[tx] = ok;
    result[tx].cost = ok ? cost : LARGE_COST;

    pRefY[tx] = dev_get_ref_block<pixel_t, NPEL>(pRefBY, nPitchY, nImgPitchY, x, y);
    pRefU[tx] = dev_get_ref_block<pixel_t, NPEL>(pRefBU, nPitchU, nImgPitchU, x / 2, y / 2);
    pRefV[tx] = dev_get_ref_block<pixel_t, NPEL>(pRefBV, nPitchV, nImgPitchV, x / 2, y / 2);
  }

  __syncthreads();

  if (isVectorOK[bx]) {
    sad_t sad = dev_calc_sad<pixel_t, BLK_SIZE>(wi, pSrcY, pSrcU, pSrcV, pRefY[bx], pRefU[bx], pRefV[bx], nPitchY, nPitchU, nPitchV);
    if (wi == 0) {
      result[bx].cost += (sad * PENALTY_NEW) >> 8;
    }
  }

  __syncthreads();

  // ���ʏW��
  if (tx < 4) { // reduce��8-4=4�X���b�h�ŌĂ�
    dev_reduce_result<8>(result, tx);

    if (tx == 0) { // tx == 0�͍Ō�̃f�[�^����������ł���̂ŃA�N�Z�XOK
      if (result[0].cost < bestResult.cost) {
        bestResult = result[0];
      }
    }
  }
}

// __syncthreads()���Ăяo���Ă���̂őS���ŌĂ�
template <typename pixel_t, int BLK_SIZE, int NPEL>
__device__ void dev_expanding_search_2(
  int tx, int wi, int bx, int cx, int cy,
  const int* data, const sad_t* dataf,
  CostResult& bestResult,
  const pixel_t* pSrcY, const pixel_t* pSrcU, const pixel_t* pSrcV,
  const pixel_t* __restrict__ pRefBY, const pixel_t* __restrict__ pRefBU, const pixel_t* __restrict__ pRefBV,
  int nPitchY, int nPitchU, int nPitchV,
  int nImgPitchY, int nImgPitchU, int nImgPitchV)
{
  int2 area[] = {
    { -2, -2 },
    { -1, -2 },
    { 0, -2 },
    { 1, -2 },
    { 2, -2 },

    { -2, -1 },
    { 2, -1 },
    { -2, 0 },
    { 2, 0 },
    { -2, 1 },
    { 2, 1 },

    { -2, 2 },
    { -1, 2 },
    { 0, 2 },
    { 1, 2 },
    { 2, 2 }
  };

  __shared__ bool isVectorOK[16];
  __shared__ CostResult result[16];
  __shared__ const pixel_t* pRefY[16];
  __shared__ const pixel_t* pRefU[16];
  __shared__ const pixel_t* pRefV[16];

  if (tx < 16) {
    int x = result[tx].xy.x = cx + area[tx].x;
    int y = result[tx].xy.y = cy + area[tx].y;
    bool ok = dev_check_mv(x, y, CLIP_RECT);
    int cost = (LAMBDA * dev_sq_norm(x, y, PRED_X, PRED_Y)) >> 8;

    // no additional SAD calculations if partial sum is already above minCost
    if (cost >= bestResult.cost) {
      ok = false;
    }

    isVectorOK[tx] = ok;
    result[tx].cost = ok ? cost : LARGE_COST;

    pRefY[tx] = dev_get_ref_block<pixel_t, NPEL>(pRefBY, nPitchY, nImgPitchY, x, y);
    pRefU[tx] = dev_get_ref_block<pixel_t, NPEL>(pRefBU, nPitchU, nImgPitchU, x / 2, y / 2);
    pRefV[tx] = dev_get_ref_block<pixel_t, NPEL>(pRefBV, nPitchV, nImgPitchV, x / 2, y / 2);
  }

  __syncthreads();

  if (isVectorOK[bx]) {
    sad_t sad = dev_calc_sad<pixel_t, BLK_SIZE>(wi, pSrcY, pSrcU, pSrcV, pRefY[bx], pRefU[bx], pRefV[bx], nPitchY, nPitchU, nPitchV);
    if (wi == 0) {
      result[bx].cost += (sad * PENALTY_NEW) >> 8;
    }
  }
  int bx2 = bx + 8;
  if (isVectorOK[bx2]) {
    sad_t sad = dev_calc_sad<pixel_t, BLK_SIZE>(wi, pSrcY, pSrcU, pSrcV, pRefY[bx2], pRefU[bx2], pRefV[bx2], nPitchY, nPitchU, nPitchV);
    if (wi == 0) {
      result[bx2].cost += (sad * PENALTY_NEW) >> 8;
    }
  }

  __syncthreads();

  // ���ʏW��
  if (tx < 8) { // reduce��16-8=8�X���b�h�ŌĂ�
    dev_reduce_result<16>(result, tx);

    if (tx == 0) { // tx == 0�͍Ō�̃f�[�^����������ł���̂ŃA�N�Z�XOK
      if (result[0].cost < bestResult.cost) {
        bestResult = result[0];
      }
    }
  }
}

// __syncthreads()���Ăяo���Ă���̂őS���ŌĂ�
template <typename pixel_t, int BLK_SIZE, int NPEL>
__device__ void dev_hex2_search_1(
  int tx, int wi, int bx, int cx, int cy,
  const int* data, const sad_t* dataf,
  CostResult& bestResult,
  const pixel_t* pSrcY, const pixel_t* pSrcU, const pixel_t* pSrcV,
  const pixel_t* __restrict__ pRefBY, const pixel_t* __restrict__ pRefBU, const pixel_t* __restrict__ pRefBV,
  int nPitchY, int nPitchU, int nPitchV,
  int nImgPitchY, int nImgPitchU, int nImgPitchV)
{
  int2 area[] = { { -1,-2 },{ -2,0 },{ -1,2 },{ 1,2 },{ 2,0 },{ 1,-2 },{ -1,-2 },{ -2,0 } };

  __shared__ bool isVectorOK[8];
  __shared__ CostResult result[8];
  __shared__ const pixel_t* pRefY[8];
  __shared__ const pixel_t* pRefU[8];
  __shared__ const pixel_t* pRefV[8];

  isVectorOK[tx] = false;

  if (tx < 6) {
    int x = result[tx].xy.x = cx + area[tx].x;
    int y = result[tx].xy.y = cy + area[tx].y;
    bool ok = dev_check_mv(x, y, CLIP_RECT);
    int cost = (LAMBDA * dev_sq_norm(x, y, PRED_X, PRED_Y)) >> 8;

    // no additional SAD calculations if partial sum is already above minCost
    if (cost >= bestResult.cost) {
      ok = false;
    }

    isVectorOK[tx] = ok;
    result[tx].cost = ok ? cost : LARGE_COST;

    pRefY[tx] = dev_get_ref_block<pixel_t, NPEL>(pRefBY, nPitchY, nImgPitchY, x, y);
    pRefU[tx] = dev_get_ref_block<pixel_t, NPEL>(pRefBU, nPitchU, nImgPitchU, x / 2, y / 2);
    pRefV[tx] = dev_get_ref_block<pixel_t, NPEL>(pRefBV, nPitchV, nImgPitchV, x / 2, y / 2);
  }

  __syncthreads();

  if (isVectorOK[bx]) {
    sad_t sad = dev_calc_sad<pixel_t, BLK_SIZE>(wi, pSrcY, pSrcU, pSrcV, pRefY[bx], pRefU[bx], pRefV[bx], nPitchY, nPitchU, nPitchV);
    if (wi == 0) {
      result[bx].cost += (sad * PENALTY_NEW) >> 8;
    }
  }

  __syncthreads();

  // ���ʏW��
  if (tx < 2) { // reduce��6-4=2�X���b�h�ŌĂ�
    dev_reduce_result<8>(result, tx);

    if (tx == 0) { // tx == 0�͍Ō�̃f�[�^����������ł���̂ŃA�N�Z�XOK
      if (result[0].cost < bestResult.cost) {
        bestResult = result[0];
      }
    }
  }
}

// SRCH_DIMX % BLK_SIZE == 0������
template <typename pixel_t, int BLK_SIZE>
__device__ void dev_read_pixels(int tx, const pixel_t* src, int nPitch, int offx, int offy, pixel_t *dst)
{
  int y = tx / BLK_SIZE;
  int x = tx % BLK_SIZE;
  for (; y < BLK_SIZE; y += SRCH_DIMX / BLK_SIZE) {
    dst[x + y * BLK_SIZE] = src[(x + offx) + (y + offy) * nPitch];
  }
}

template <typename pixel_t, int BLK_SIZE, int SEARCH, int NPEL>
__global__ void kl_search(
  int nBlkX, int nBlkY, const SearchBlock* __restrict__ blocks,
  short2* vectors, // [x,y]
  int nHPad, int nVPad,
  const pixel_t* __restrict__ pSrcY, const pixel_t* __restrict__ pSrcU, const pixel_t* __restrict__ pSrcV,
  const pixel_t* __restrict__ pRefY, const pixel_t* __restrict__ pRefU, const pixel_t* __restrict__ pRefV,
  int nPitchY, int nPitchU, int nPitchV,
  int nImgPitchY, int nImgPitchU, int nImgPitchV
)
{
  enum {
    BLK_SIZE_UV = BLK_SIZE / 2,
    BLK_STEP = BLK_SIZE / 2,
  };

  const int tx = threadIdx.x;
  const int wi = tx % 16;
  const int bx = tx / 16;

  for (int blkx = blockIdx.x; blkx < nBlkX; blkx += blockDim.x) {
    for (int blky = 0; blky < nBlkY; ++blky) {

      // src��shared memory�ɓ]��
      int offx = nHPad + blkx * BLK_STEP;
      int offy = nVPad + blky * BLK_STEP;

      __shared__ pixel_t srcY[BLK_SIZE * BLK_SIZE];
      __shared__ pixel_t srcU[BLK_SIZE_UV * BLK_SIZE_UV];
      __shared__ pixel_t srcV[BLK_SIZE_UV * BLK_SIZE_UV];

      dev_read_pixels<pixel_t, BLK_SIZE>(tx, pSrcY, nPitchY, offx, offy, srcY);
      dev_read_pixels<pixel_t, BLK_SIZE_UV>(tx, pSrcU, nPitchU, offx / 2, offy / 2, srcU);
      dev_read_pixels<pixel_t, BLK_SIZE_UV>(tx, pSrcV, nPitchV, offx / 2, offy / 2, srcV);

      __shared__ const pixel_t* pRefBY;
      __shared__ const pixel_t* pRefBU;
      __shared__ const pixel_t* pRefBV;

      if (tx == 0) {
        pRefBY = &pRefY[offx + offy * nPitchY];
        pRefBU = &pRefU[offx / 2 + offy / 2 * nPitchU];
        pRefBV = &pRefV[offx / 2 + offy / 2 * nPitchV];
      }

      // �p�����[�^�Ȃǂ̃f�[�^��shared memory�Ɋi�[
      __shared__ int data[12];
      __shared__ sad_t dataf[5];

      if (tx < 12) {
        int blkIdx = blky*nBlkX + blkx;
        data[tx] = blocks[blkIdx].data[tx];
        if (tx < 5) {
          dataf[tx] = blocks[blkIdx].dataf[tx];
        }
      }

      __syncthreads();

      // FetchPredictors
      __shared__ CostResult result[8];
      __shared__ const pixel_t* pRefY[8];
      __shared__ const pixel_t* pRefU[8];
      __shared__ const pixel_t* pRefV[8];

      if (tx < 6) {
        __shared__ volatile short pred[7][2]; // x, y

        // zero, global, predictor, predictors[1]�`[3]���擾
        short2 vec = vectors[REF_VECTOR_INDEX[tx]];
        dev_clip_mv(vec, CLIP_RECT);
        pred[tx][0] = vec.x;
        pred[tx][1] = vec.y;
        // memfence
        if (tx < 2) {
          // Median predictor
          // �v�Z�����������̂ŏ��������E�E�E
          int a = pred[3][tx];
          int b = pred[4][tx];
          int c = pred[5][tx];
          int max_ = dev_max(a, b, c);
          int min_ = dev_min(a, b, c);
          int med_ = a + b + c - max_ - min_;
          pred[6][tx] = med_;
        }
        // memfence
        int x = result[tx].xy.x = pred[tx][0];
        int y = result[tx].xy.y = pred[tx][1];
        result[tx].cost = (LAMBDA * dev_sq_norm(x, y, PRED_X, PRED_Y)) >> 8;

        pRefY[tx] = dev_get_ref_block<pixel_t, NPEL>(pRefBY, nPitchY, nImgPitchY, x, y);
        pRefU[tx] = dev_get_ref_block<pixel_t, NPEL>(pRefBU, nPitchU, nImgPitchU, x / 2, y / 2);
        pRefV[tx] = dev_get_ref_block<pixel_t, NPEL>(pRefBV, nPitchV, nImgPitchV, x / 2, y / 2);
      }

      __syncthreads();

      // �܂���7�ӏ����v�Z
      if (bx < 7) {
        sad_t sad = dev_calc_sad<pixel_t, BLK_SIZE>(wi, srcY, srcU, srcV, pRefY[bx], pRefU[bx], pRefV[bx], nPitchY, nPitchU, nPitchV);
        if (wi == 0) {
          if (bx < 3) {
            // pzero, pglobal, 1
            result[bx].cost = (sad * PENALTIES[bx]) >> 8;
          }
          else {
            result[bx].cost += sad;
          }
        }
        // �Ƃ肠������r��cost�����ł��̂�SAD�͗v��Ȃ�
        // SAD�͒T�����I�������Čv�Z����
      }

      __syncthreads();

      // ���ʏW��
      if (tx < 3) { // 7-4=3�X���b�h�ŌĂ�
        dev_reduce_result<8>(result, tx);
      }

      __syncthreads();

      // Refine
      if (SEARCH == 1) {
        // EXHAUSTIVE
        int bmx = result[0].xy.x;
        int bmy = result[0].xy.y;
        dev_expanding_search_1<pixel_t, BLK_SIZE, NPEL>(
          tx, wi, bx, bmx, bmy, data, dataf, result[0],
          srcY, srcU, srcV, pRefBY, pRefBU, pRefBV,
          nPitchY, nPitchU, nPitchV, nImgPitchY, nImgPitchU, nImgPitchV);
        dev_expanding_search_2<pixel_t, BLK_SIZE, NPEL>(
          tx, wi, bx, bmx, bmy, data, dataf, result[0],
          srcY, srcU, srcV, pRefBY, pRefBU, pRefBV,
          nPitchY, nPitchU, nPitchV, nImgPitchY, nImgPitchU, nImgPitchV);
      }
      else if (SEARCH == 2) {
        // HEX2SEARCH
        dev_hex2_search_1<pixel_t, BLK_SIZE, NPEL>(
          tx, wi, bx, result[0].xy.x, result[0].xy.y, data, dataf, result[0],
          srcY, srcU, srcV, pRefBY, pRefBU, pRefBV,
          nPitchY, nPitchU, nPitchV, nImgPitchY, nImgPitchU, nImgPitchV);
        dev_expanding_search_1<pixel_t, BLK_SIZE, NPEL>(
          tx, wi, bx, result[0].xy.x, result[0].xy.y, data, dataf, result[0],
          srcY, srcU, srcV, pRefBY, pRefBU, pRefBV,
          nPitchY, nPitchU, nPitchV, nImgPitchY, nImgPitchU, nImgPitchV);
      }

      // ���ʏ�������
      if (tx == 0) {
        vectors[blky*nBlkX + blkx] = result[0].xy;
      }

      // ���L�������ی�
      __syncthreads();
    }
  }
}



