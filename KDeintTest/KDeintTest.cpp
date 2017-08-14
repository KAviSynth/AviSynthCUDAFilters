
#define _CRT_SECURE_NO_WARNINGS

#include <Windows.h>

#define AVS_LINKAGE_DLLIMPORT
#include "avisynth.h"
#pragma comment(lib, "avisynth.lib")

#include "gtest/gtest.h"

#include <fstream>
#include <string>
#include <iostream>

std::string GetDirectoryName(const std::string& filename)
{
	std::string directory;
	const size_t last_slash_idx = filename.rfind('\\');
	if (std::string::npos != last_slash_idx)
	{
		directory = filename.substr(0, last_slash_idx);
	}
	return directory;
}

// �e�X�g�ΏۂƂȂ�N���X Foo �̂��߂̃t�B�N�X�`��
class TestBase : public ::testing::Test {
protected:
	TestBase() { }

	virtual ~TestBase() {
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
};

TEST_F(TestBase, AnalyzeCUDATest)
{
	try {
		IScriptEnvironment2* env = CreateScriptEnvironment2();

		AVSValue result;
		std::string kdeintPath = modulePath + "\\KDeint.dll";
		env->LoadPlugin(kdeintPath.c_str(), true, &result);

		std::string script = "LWLibavVideoSource(\"test.ts\")\n"
			"s = KMSuper()\n"
			"kap = s.KMPartialSuper().KMAnalyse(isb = true, delta = 1, blksize = 16, overlap = 8, lambda = 400, global = true, meander = false)\n"
			"karef = s.KMAnalyse(isb = true, delta = 1, blksize = 16, overlap = 8, lambda = 400, global = true, meander = false, partial = kap)\n"
			"kacuda = s.OnCPU(0).KMAnalyse(isb = true, delta = 1, blksize = 16, overlap = 8, lambda = 400, global = true, meander = false, partial = kap.OnCPU(0)).OnCUDA(0)\n"
			"KMAnalyzeCheck2(karef, kacuda, last)";

		std::string scriptpath = workDirPath + "\\script.avs";

		std::ofstream out(scriptpath);
		out << script;
		out.close();

		{
			PClip clip = env->Invoke("Import", scriptpath.c_str()).AsClip();
			clip->GetFrame(100, env);
		}

		env->DeleteScriptEnvironment();
	}
	catch (const AvisynthError& err) {
		printf("%s\n", err.msg);
		GTEST_FAIL();
	}
}

int main(int argc, char **argv)
{
	::testing::GTEST_FLAG(filter) = "*AnalyzeCUDATest";
	::testing::InitGoogleTest(&argc, argv);
	int result = RUN_ALL_TESTS();

	getchar();

	return result;
}

