#pragma once

#define _CRT_SECURE_NO_WARNINGS

#define AVS_LINKAGE_DLLIMPORT
#include "avisynth.h"

#define NOMINMAX
#include <Windows.h>

#include "gtest/gtest.h"

#include <fstream>
#include <string>
#include <iostream>
#include <memory>

#define O_C(n) ".OnCUDA(" #n ", 0)"

std::string GetDirectoryName(const std::string& filename);

struct ScriptEnvironmentDeleter {
  void operator()(IScriptEnvironment* env) {
    env->DeleteScriptEnvironment();
  }
};

typedef std::unique_ptr<IScriptEnvironment2, ScriptEnvironmentDeleter> PEnv;

class AvsTestBase : public ::testing::Test {
protected:
  AvsTestBase() { }

  virtual ~AvsTestBase() {
    // �e�X�g���Ɏ��s�����C��O�𓊂��Ȃ� clean-up �������ɏ����܂��D
  }

  // �R���X�g���N�^�ƃf�X�g���N�^�ł͕s�\���ȏꍇ�D
  // �ȉ��̃��\�b�h���`���邱�Ƃ��ł��܂��F

  virtual void SetUp() {
    // ���̃R�[�h�́C�R���X�g���N�^�̒���i�e�e�X�g�̒��O�j
    // �ɌĂяo����܂��D
    char buf[MAX_PATH];
    GetModuleFileName(nullptr, buf, MAX_PATH);
    modulePath = GetDirectoryName(buf);
    workDirPath = GetDirectoryName(GetDirectoryName(modulePath)) + "\\TestScripts";
  }

  virtual void TearDown() {
    // ���̃R�[�h�́C�e�e�X�g�̒���i�f�X�g���N�^�̒��O�j
    // �ɌĂяo����܂��D
  }

  std::string modulePath;
  std::string workDirPath;

  enum TEST_FRAMES {
    TF_MID, TF_BEGIN, TF_END, TF_100
  };

  void GetFrames(PClip& clip, TEST_FRAMES tf, PNeoEnv env);
};

