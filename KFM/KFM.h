#pragma once

#include "Frame.h"

enum {
  OVERLAP = 8,
  VPAD = 4,

  MOVE = 1,
  SHIMA = 2,
  LSHIMA = 4,
};

struct FMCount {
  int move, shima, lshima;
};

struct PulldownPatternField {
	bool split; // ���̃t�B�[���h�Ƃ͕ʃt���[��
	bool merge; // 3�t�B�[���h�̍ŏ��̃t�B�[���h
  bool shift; // ���24p�t���[�����Q�Ƃ���t�B�[���h
};

struct PulldownPattern {
  PulldownPatternField fields[10 * 4];
  int cycle;

	PulldownPattern(int nf0, int nf1, int nf2, int nf3); // 24p
	PulldownPattern(); // 30p

  // �p�^�[����10�t�B�[���h+�O��2�t�B�[���h���̍��킹��
  // 14�t�B�[���h�����݂�z��B14�t�B�[���h�̑O���ւ̃|�C���^��Ԃ�
  const PulldownPatternField* GetPattern(int n) const {
    return &fields[10 + n - 2];
  }
  int GetCycleLength() const {
    return cycle;
  }
};

struct Frame24Info {
  int cycleIndex;
  int frameIndex; // �T�C�N�����̃t���[���ԍ�
  int fieldStartIndex; // �\�[�X�t�B�[���h�J�n�ԍ�
  int numFields; // �\�[�X�t�B�[���h��
  int fieldShift; // 2224�p�^�[����2323�ϊ�����ꍇ�̂��炵���K�v�̓t���[��
};

struct FMData;

class PulldownPatterns
{
  enum { NUM_PATTERNS = 21 };
  PulldownPattern p2323, p2233, p2224, p30;
  int patternOffsets[4];
  const PulldownPatternField* allpatterns[NUM_PATTERNS];
public:
  PulldownPatterns();

  const PulldownPatternField* GetPattern(int patternIndex) const {
    return allpatterns[patternIndex];
  }

  const char* PatternToString(int patternIndex, int& index) const;

  // �p�^�[����24fps�̃t���[���ԍ�����t���[�������擾
  Frame24Info GetFrame24(int patternIndex, int n24) const;

  // �p�^�[����60fps�̃t���[���ԍ�����t���[�������擾
  // frameIndex < 0 or frameIndex >= 4�̏ꍇ�A
  // fieldStartIndex��numFields�͐������Ȃ��\��������̂Œ���
  Frame24Info GetFrame60(int patternIndex, int n60) const;

  std::pair<int, float> Matching(const FMData* data, int width, int height, float costth, bool enable30p) const;

	static bool Is30p(int patternIndex) { return patternIndex == NUM_PATTERNS - 1; }
};

enum {
  COMBE_FLAG_PAD_H = 4,
  COMBE_FLAG_PAD_W = 2,
};

static Frame WrapSwitchFragFrame(const PVideoFrame& frame) {
  return Frame(frame, COMBE_FLAG_PAD_H, COMBE_FLAG_PAD_W, 1);
}

#define DECOMB_UCF_FLAG_STR "KDecombUCF_Flag"

enum DECOMB_UCF_FLAG {
  DECOMB_UCF_NONE,  // ���Ȃ�
  DECOMB_UCF_PREV,  // �O�̃t���[��
  DECOMB_UCF_NEXT,  // ���̃t���[��
  DECOMB_UCF_FIRST, // 1�Ԗڂ̃t�B�[���h��bob
  DECOMB_UCF_SECOND,// 2�Ԗڂ̃t�B�[���h��bob
  DECOMB_UCF_NR,    // �����t���[��
};

int GetDeviceTypes(const PClip& clip);
