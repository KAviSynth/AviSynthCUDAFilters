#pragma once

enum {
  OVERLAP = 8,
  BLOCK_SIZE = OVERLAP * 2,
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
};

struct PulldownPattern {
  PulldownPatternField fields[10 * 4];

	PulldownPattern(int nf0, int nf1, int nf2, int nf3);
	PulldownPattern();

  const PulldownPatternField* GetPattern(int n) const {
    return &fields[10 + n - 2];
  }
};

struct Frame24Info {
  int cycleIndex;
  int frameIndex; // �T�C�N�����̃t���[���ԍ�
  int fieldStartIndex; // �\�[�X�t�B�[���h�J�n�ԍ�
  int numFields; // �\�[�X�t�B�[���h��
};

struct FMData;

class PulldownPatterns
{
  PulldownPattern p2323, p2233, p30;
  const PulldownPatternField* allpatterns[27];
public:
  PulldownPatterns();

  const PulldownPatternField* GetPattern(int patternIndex) const {
    return allpatterns[patternIndex];
  }

  // �p�^�[����24fps�̃t���[���ԍ�����t���[�������擾
  Frame24Info GetFrame24(int patternIndex, int n24) const;

  // �p�^�[����60fps�̃t���[���ԍ�����t���[�������擾
  // frameIndex < 0 or frameIndex >= 4�̏ꍇ�A
  // fieldStartIndex��numFields�͐������Ȃ��\��������̂Œ���
  Frame24Info GetFrame60(int patternIndex, int n60) const;

  std::pair<int, float> Matching(const FMData* data, int width, int height, float costth) const;

	static bool Is30p(int patternIndex) { return patternIndex >= 18; }
};

#define COMBE_FLAG_STR "KRemoveCombe_Flag"

int GetDeviceTypes(const PClip& clip);
