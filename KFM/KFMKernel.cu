
#include <stdint.h>
#include <avisynth.h>

#include <algorithm>
#include <memory>

#include "CommonFunctions.h"
#include "KFM.h"
#include "TextOut.h"

#include "VectorFunctions.cuh"
#include "ReduceKernel.cuh"
#include "KFMFilterBase.cuh"

class KPatchCombe : public KFMFilterBase
{
  PClip clip60;
  PClip combemaskclip;
  PClip containscombeclip;
  PClip fmclip;

  PulldownPatterns patterns;

  template <typename pixel_t>
  PVideoFrame GetFrameT(int n, PNeoEnv env)
  {
    PDevice cpuDevice = env->GetDevice(DEV_TYPE_CPU, 0);

    {
      Frame containsframe = env->GetFrame(containscombeclip, n, cpuDevice);
      if (*containsframe.GetReadPtr<int>() == 0) {
        // �_���ȃu���b�N�͂Ȃ��̂ł��̂܂ܕԂ�
        return child->GetFrame(n, env);
      }
    }

    int cycleIndex = n / 4;
    Frame fmframe = env->GetFrame(fmclip, cycleIndex, cpuDevice);
    int kfmPattern = fmframe.GetProperty("KFM_Pattern", -1);
    if (kfmPattern == -1) {
      env->ThrowError("[KPatchCombe] Failed to get frame info. Check fmclip");
    }
    Frame24Info frameInfo = patterns.GetFrame24(kfmPattern, n);

    int fieldIndex[] = { 1, 3, 6, 8 };
    // �W���ʒu
    int n60 = fieldIndex[n % 4];
    // �t�B�[���h�Ώ۔͈͂ɕ␳
    n60 = clamp(n60, frameInfo.fieldStartIndex, frameInfo.fieldStartIndex + frameInfo.numFields - 1);
    n60 += cycleIndex * 10;

    Frame baseFrame = child->GetFrame(n, env);
    Frame frame60 = child->GetFrame(n60, env);
    Frame mflag = combemaskclip->GetFrame(n, env);

    // �_���ȃu���b�N��bob�t���[������R�s�[
    Frame dst = env->NewVideoFrame(vi);
    MergeBlock<pixel_t>(baseFrame, frame60, mflag, dst, env);

    return dst.frame;
  }

public:
  KPatchCombe(PClip clip24, PClip clip60, PClip fmclip, PClip combemaskclip, PClip containscombeclip, IScriptEnvironment* env)
    : KFMFilterBase(clip24)
    , clip60(clip60)
    , combemaskclip(combemaskclip)
    , containscombeclip(containscombeclip)
    , fmclip(fmclip)
  {
    //
  }

  PVideoFrame __stdcall GetFrame(int n, IScriptEnvironment* env_)
  {
    PNeoEnv env = env_;

    int pixelSize = vi.ComponentSize();
    switch (pixelSize) {
    case 1:
      return GetFrameT<uint8_t>(n, env);
    case 2:
      return GetFrameT<uint16_t>(n, env);
    default:
      env->ThrowError("[KPatchCombe] Unsupported pixel format");
    }

    return PVideoFrame();
  }

  static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
  {
    return new KPatchCombe(
      args[0].AsClip(),       // clip24
      args[1].AsClip(),       // clip60
      args[2].AsClip(),       // fmclip
      args[3].AsClip(),       // combemaskclip
      args[4].AsClip(),       // containscombeclip
      env
    );
  }
};

enum KFMSWTICH_FLAG {
  FRAME_60 = 1,
	FRAME_24,
  FRAME_UCF,
};

class KFMSwitch : public KFMFilterBase
{
	typedef uint8_t pixel_t;

	PClip clip24;
	PClip fmclip;
  PClip combemaskclip;
  PClip containscombeclip;
  PClip ucfclip;
	float thswitch;
	bool show;
	bool showflag;

	int logUVx;
	int logUVy;
	int nBlkX, nBlkY;

  VideoInfo workvi;

	PulldownPatterns patterns;

	template <typename pixel_t>
	void VisualizeFlag(Frame& dst, Frame& flag, PNeoEnv env)
	{
		// ���茋�ʂ�\��
		int blue[] = { 73, 230, 111 };

		pixel_t* dstY = dst.GetWritePtr<pixel_t>(PLANAR_Y);
		pixel_t* dstU = dst.GetWritePtr<pixel_t>(PLANAR_U);
		pixel_t* dstV = dst.GetWritePtr<pixel_t>(PLANAR_V);
    const uint8_t* flagY = flag.GetReadPtr<uint8_t>(PLANAR_Y);
    const uint8_t* flagC = flag.GetReadPtr<uint8_t>(PLANAR_U);

		int dstPitchY = dst.GetPitch<pixel_t>(PLANAR_Y);
		int dstPitchUV = dst.GetPitch<pixel_t>(PLANAR_U);
    int fpitchY = flag.GetPitch<uint8_t>(PLANAR_Y);
    int fpitchUV = flag.GetPitch<uint8_t>(PLANAR_U);

		// �F��t����
		for (int y = 0; y < vi.height; ++y) {
			for (int x = 0; x < vi.width; ++x) {
        int coefY = flagY[x + y * fpitchY];
				int offY = x + y * dstPitchY;
        dstY[offY] = (blue[0] * coefY + dstY[offY] * (128 - coefY)) >> 7;
        
        int coefC = flagC[(x >> logUVx) + (y >> logUVy) * fpitchUV];
				int offUV = (x >> logUVx) + (y >> logUVy) * dstPitchUV;
				dstU[offUV] = (blue[1] * coefC + dstU[offUV] * (128 - coefC)) >> 7;
				dstV[offUV] = (blue[2] * coefC + dstV[offUV] * (128 - coefC)) >> 7;
			}
		}
	}

	template <typename pixel_t>
	Frame InternalGetFrame(int n60, Frame& fmframe, int& type, PNeoEnv env)
	{
		int cycleIndex = n60 / 10;
		int kfmPattern = fmframe.GetProperty("KFM_Pattern", -1);
    if (kfmPattern == -1) {
      env->ThrowError("[KFMSwitch] Failed to get frame info. Check fmclip");
    }
		float kfmCost = (float)fmframe.GetProperty("KFM_Cost", 1.0);
    Frame baseFrame;

		if (kfmCost > thswitch || PulldownPatterns::Is30p(kfmPattern)) {
			// �R�X�g�������̂�60p�Ɣ��f or 30p�̏ꍇ
      type = FRAME_60;

      if (ucfclip) {
        baseFrame = ucfclip->GetFrame(n60, env);
        auto prop = baseFrame.GetProperty(DECOMB_UCF_FLAG_STR);
        if (prop == nullptr) {
          env->ThrowError("Invalid UCF clip");
        }
        auto flag = (DECOMB_UCF_FLAG)prop->GetInt();
        if (flag == DECOMB_UCF_NEXT || flag == DECOMB_UCF_PREV) {
          // �t���[���u�������ꂽ�ꍇ�́A60p�����}�[�W���������s����
          type = FRAME_UCF;
        }
        else {
          return baseFrame;
        }
      }
      else {
        return child->GetFrame(n60, env);
      }
		}
    else {
      type = FRAME_24;
    }

    // �����ł�type�� 24 or UCF

		// 24p�t���[���ԍ����擾
		Frame24Info frameInfo = patterns.GetFrame60(kfmPattern, n60);
		int n24 = frameInfo.cycleIndex * 4 + frameInfo.frameIndex + frameInfo.fieldShift;

		if (frameInfo.frameIndex < 0) {
			// �O�ɋ󂫂�����̂őO�̃T�C�N��
			n24 = frameInfo.cycleIndex * 4 - 1;
		}
		else if (frameInfo.frameIndex >= 4) {
			// ���̃T�C�N���̃p�^�[�����擾
			Frame nextfmframe = fmclip->GetFrame(cycleIndex + 1, env);
			int nextPattern = nextfmframe.GetProperty("KFM_Pattern", -1);
			int fstart = patterns.GetFrame24(nextPattern, 0).fieldStartIndex;
			if (fstart > 0) {
				// �O�ɋ󂫂�����̂őO�̃T�C�N��
				n24 = frameInfo.cycleIndex * 4 + 3;
			}
			else {
				// �O�ɋ󂫂��Ȃ��̂Ō��̃T�C�N��
				n24 = frameInfo.cycleIndex * 4 + 4;
			}
		}

		Frame frame24 = clip24->GetFrame(n24, env);

    if (type == FRAME_24) {
      baseFrame = frame24;
    }

		{
      Frame containsframe = env->GetFrame(containscombeclip, n24, env->GetDevice(DEV_TYPE_CPU, 0));
      if (*containsframe.GetReadPtr<int>() == 0) {
        // �_���ȃu���b�N�͂Ȃ��̂ł��̂܂ܕԂ�
        return baseFrame;
      }
		}

    Frame frame60 = child->GetFrame(n60, env);
    Frame mflag = combemaskclip->GetFrame(n24, env);

		if (!IS_CUDA && vi.ComponentSize() == 1 && showflag) {
			env->MakeWritable(&baseFrame.frame);
			VisualizeFlag<pixel_t>(baseFrame, mflag, env);
			return baseFrame;
		}

		// �_���ȃu���b�N��bob�t���[������R�s�[
		Frame dst = env->NewVideoFrame(vi);
		MergeBlock<pixel_t>(baseFrame, frame60, mflag, dst, env);

		return dst;
	}

  template <typename pixel_t>
  PVideoFrame GetFrameTop(int n60, PNeoEnv env)
  {
    int cycleIndex = n60 / 10;
    Frame fmframe = env->GetFrame(fmclip, cycleIndex, env->GetDevice(DEV_TYPE_CPU, 0));
    int frameType;

    Frame dst = InternalGetFrame<pixel_t>(n60, fmframe, frameType, env);

    if (show) {
      const std::pair<int, float>* pfm = fmframe.GetReadPtr<std::pair<int, float>>();
      const char* fps = (frameType == FRAME_60) ? "60p" : (frameType == FRAME_24) ? "24p" : "UCF";
      char buf[100]; sprintf(buf, "KFMSwitch: %s pattern:%2d cost:%.1f", fps, pfm->first, pfm->second);
      DrawText<pixel_t>(dst.frame, vi.BitsPerComponent(), 0, 0, buf, env);
      return dst.frame;
    }

    return dst.frame;
  }

public:
	KFMSwitch(PClip clip60, PClip clip24, PClip fmclip, PClip combemaskclip, PClip containscombeclip, PClip ucfclip,
		float thswitch, bool show, bool showflag, IScriptEnvironment* env)
		: KFMFilterBase(clip60)
		, clip24(clip24)
		, fmclip(fmclip)
    , combemaskclip(combemaskclip)
    , containscombeclip(containscombeclip)
    , ucfclip(ucfclip)
		, thswitch(thswitch)
		, show(show)
		, showflag(showflag)
		, logUVx(vi.GetPlaneWidthSubsampling(PLANAR_U))
		, logUVy(vi.GetPlaneHeightSubsampling(PLANAR_U))
	{
		if (vi.width & 7) env->ThrowError("[KFMSwitch]: width must be multiple of 8");
		if (vi.height & 7) env->ThrowError("[KFMSwitch]: height must be multiple of 8");


		nBlkX = nblocks(vi.width, OVERLAP);
		nBlkY = nblocks(vi.height, OVERLAP);

    // check clip device
    if (!(GetDeviceTypes(fmclip) & DEV_TYPE_CPU)) {
      env->ThrowError("[KFMSwitch]: fmclip must be CPU device");
    }
    if (!(GetDeviceTypes(containscombeclip) & DEV_TYPE_CPU)) {
      env->ThrowError("[KFMSwitch]: containscombeclip must be CPU device");
    }

    auto devs = GetDeviceTypes(clip60);
    if (!(GetDeviceTypes(clip24) & devs)) {
      env->ThrowError("[KFMSwitch]: clip24 device unmatch");
    }
    if (!(GetDeviceTypes(combemaskclip) & devs)) {
      env->ThrowError("[KFMSwitch]: combeclip device unmatch");
    }
    if (!(GetDeviceTypes(clip24) & devs)) {
      env->ThrowError("[KFMSwitch]: clip24 device unmatch");
    }
    if (ucfclip && !(GetDeviceTypes(ucfclip) & devs)) {
      env->ThrowError("[KFMSwitch]: ucfclip device unmatch");
    }
	}

	PVideoFrame __stdcall GetFrame(int n60, IScriptEnvironment* env_)
	{
		PNeoEnv env = env_;

		int pixelSize = vi.ComponentSize();
		switch (pixelSize) {
		case 1:
			return GetFrameTop<uint8_t>(n60, env);
		case 2:
      return GetFrameTop<uint16_t>(n60, env);
		default:
			env->ThrowError("[KFMSwitch] Unsupported pixel format");
			break;
		}

		return PVideoFrame();
	}

	static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
	{
		return new KFMSwitch(
			args[0].AsClip(),           // clip60
			args[1].AsClip(),           // clip24
			args[2].AsClip(),           // fmclip
      args[3].AsClip(),           // combemaskclip
      args[4].AsClip(),           // containscombeclip
      args[5].Defined() ? args[5].AsClip() : nullptr,           // ucfclip
      (float)args[6].AsFloat(0.8f),// thswitch
			args[7].AsBool(false),      // show
			args[8].AsBool(false),      // showflag
			env
			);
	}
};

class KFMPad : public KFMFilterBase
{
  VideoInfo srcvi;

  template <typename pixel_t>
  PVideoFrame GetFrameT(int n, PNeoEnv env)
  {
    Frame src = child->GetFrame(n, env);
    Frame dst = Frame(env->NewVideoFrame(vi), VPAD);

    CopyFrame<pixel_t>(src, dst, env);
    PadFrame<pixel_t>(dst, env);

    return dst.frame;
  }
public:
  KFMPad(PClip src, IScriptEnvironment* env)
    : KFMFilterBase(src)
    , srcvi(vi)
  {
    if (srcvi.width & 3) env->ThrowError("[KFMPad]: width must be multiple of 4");
    if (srcvi.height & 3) env->ThrowError("[KFMPad]: height must be multiple of 4");

    vi.height += VPAD * 2;
  }

  PVideoFrame __stdcall GetFrame(int n, IScriptEnvironment* env_)
  {
    PNeoEnv env = env_;

    int pixelSize = vi.ComponentSize();
    switch (pixelSize) {
    case 1:
      return GetFrameT<uint8_t>(n, env);
    case 2:
      return GetFrameT<uint16_t>(n, env);
    default:
      env->ThrowError("[KFMPad] Unsupported pixel format");
      break;
    }

    return PVideoFrame();
  }

  static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
  {
    return new KFMPad(
      args[0].AsClip(),       // src
      env
    );
  }
};


class AssumeDevice : public GenericVideoFilter
{
  int devices;
public:
  AssumeDevice(PClip clip, int devices)
    : GenericVideoFilter(clip)
    , devices(devices)
  { }

	int __stdcall SetCacheHints(int cachehints, int frame_range) {
		if (cachehints == CACHE_GET_DEV_TYPE) {
			return devices;
		}
		return 0;
	}

	static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
	{
		return new AssumeDevice(args[0].AsClip(), args[1].AsInt());
	}
};

void AddFuncFMKernel(IScriptEnvironment* env)
{
  env->AddFunction("KPatchCombe", "ccccc", KPatchCombe::Create, 0);
  env->AddFunction("KFMSwitch", "ccccc[ucfclip]c[thswitch]f[show]b[showflag]b", KFMSwitch::Create, 0);
  env->AddFunction("KFMPad", "c", KFMPad::Create, 0);
	env->AddFunction("AssumeDevice", "ci", AssumeDevice::Create, 0);
}
