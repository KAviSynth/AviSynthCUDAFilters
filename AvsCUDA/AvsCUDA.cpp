// AvsCUDA.cpp : DLL アプリケーション用にエクスポートされる関数を定義します。
//

#include <stdio.h>
#include <avisynth.h>
#include <cuda_runtime_api.h>

#include "AvsCUDA.h"

extern const FuncDefinition conditonal_functions[];

void OnCudaError(cudaError_t err) {
#if 1 // デバッグ用（本番は取り除く）
  printf("[CUDA Error] %s (code: %d)\n", cudaGetErrorString(err), err);
#endif
}

const AVS_Linkage *AVS_linkage = 0;

extern "C" __declspec(dllexport) const char* __stdcall AvisynthPluginInit3(IScriptEnvironment* env, const AVS_Linkage* const vectors)
{
   AVS_linkage = vectors;

   for (int i = 0; conditonal_functions[i].name; ++i) {
     auto def = conditonal_functions[i];
     env->AddFunction(def.name, def.params, def.func, def.user_data);
   }

   return "Avisynth CUDA Filters Plugin";
}
