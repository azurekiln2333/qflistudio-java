#include <dlfcn.h>
#include <string>
#include "napi/native_api.h"

void RegisterJdkProcesses(napi_env env, napi_value exports);

static napi_value GetLayout(napi_env env, napi_callback_info info) {
    Dl_info location;
    if (!dladdr(reinterpret_cast<void*>(&GetLayout), &location) || !location.dli_fname) {
        napi_throw_error(env, "JDK_LAYOUT", "Cannot locate the installed JDK libraries");
        return nullptr;
    }
    std::string directory(location.dli_fname);
    directory.resize(directory.find_last_of('/'));
#ifdef __aarch64__
    const char* abi = "arm64-v8a";
#else
    const char* abi = "x86_64";
#endif
    napi_value result, value;
    napi_create_object(env, &result);
    napi_create_string_utf8(env, directory.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, result, "libraryDirectory", value);
    napi_create_string_utf8(env, abi, NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, result, "abi", value);
    return result;
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor property = {"getLayout", nullptr, GetLayout, nullptr, nullptr, nullptr, napi_default, nullptr};
    napi_define_properties(env, exports, 1, &property);
    RegisterJdkProcesses(env, exports);
    return exports;
}

static napi_module module = {1, 0, nullptr, Init, "qfli_jdk_layout", nullptr, {0}};

extern "C" __attribute__((constructor)) void RegisterModule() {
    napi_module_register(&module);
}
