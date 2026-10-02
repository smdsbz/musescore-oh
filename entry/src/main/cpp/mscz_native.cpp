#include <cstring>

#include "napi/native_api.h"
#include "zip_reader.h"
#include "mscz_meta.h"

static napi_value EngineInfo(napi_env env, napi_callback_info info)
{
    napi_value result;
    napi_create_string_utf8(env, "msoh native: zip(inflate via zlib) + napi bridge ready",
                            NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value ExtractMeta(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "extractMeta(bytes: Uint8Array) requires 1 argument");
        return nullptr;
    }
    bool isTypedArray = false;
    napi_is_typedarray(env, argv[0], &isTypedArray);
    if (!isTypedArray) {
        napi_throw_type_error(env, nullptr, "argument must be Uint8Array");
        return nullptr;
    }
    void* data = nullptr;
    size_t length = 0;
    napi_typedarray_type type;
    napi_get_typedarray_info(env, argv[0], &type, &length, &data, nullptr, nullptr);
    if (type != napi_uint8_array) {
        napi_throw_type_error(env, nullptr, "argument must be Uint8Array");
        return nullptr;
    }

    std::string error;
    std::string json = msoh::ExtractMetaJson(static_cast<const uint8_t*>(data), length, error);
    if (!error.empty()) {
        napi_throw_error(env, "E_MSCZ", error.c_str());
        return nullptr;
    }

    napi_value result;
    napi_create_string_utf8(env, json.data(), json.size(), &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "engineInfo", nullptr, EngineInfo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "extractMeta", nullptr, ExtractMeta, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module msohModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "msoh",
    .nm_priv = ((void *)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterMsohModule(void)
{
    napi_module_register(&msohModule);
}
