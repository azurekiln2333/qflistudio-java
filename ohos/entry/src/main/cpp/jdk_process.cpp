#include <cerrno>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <string>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>
#include "napi/native_api.h"

namespace {
std::unordered_map<int, bool> children;

bool ReadString(napi_env env, napi_value value, std::string& result) {
    size_t length;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) return false;
    result.resize(length + 1);
    napi_get_value_string_utf8(env, value, &result[0], result.size(), &length);
    result.resize(length);
    return result.find('\0') == std::string::npos;
}

napi_value Error(napi_env env, const char* operation) {
    std::string message = std::string(operation) + ": " + std::strerror(errno);
    napi_throw_error(env, "JDK_PROCESS", message.c_str());
    return nullptr;
}

using Launch = int (*)(int, char**, int, const char**, int, const char**,
    const char*, const char*, const char*, const char*, unsigned char,
    unsigned char, unsigned char, int);

// Each invocation owns a fresh VM in a child. No ArkTS or Flutter API is called there.
[[noreturn]] void RunChild(const std::vector<std::string>& paths,
                          std::vector<std::string>& arguments, int input, int output, int error,
                          pid_t parent) {
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    if (getppid() != parent) _exit(125);
    if (dup2(input, STDIN_FILENO) < 0 || dup2(output, STDOUT_FILENO) < 0 ||
        dup2(error, STDERR_FILENO) < 0) _exit(125);
    close(input); close(output); close(error);
    if (chdir(paths[2].c_str()) != 0) {
        dprintf(STDERR_FILENO, "JDK working directory: %s\n", std::strerror(errno));
        _exit(125);
    }
    setenv("JAVA_HOME", paths[0].c_str(), 1);
    setenv("QFLI_JAVA_HOME", paths[0].c_str(), 1);
    setenv("QFLI_NATIVE_LIBRARY_DIR", paths[1].c_str(), 1);
    setenv("LD_LIBRARY_PATH", paths[1].c_str(), 1);
    std::string temp = paths[0] + "/tmp";
    setenv("TMPDIR", temp.c_str(), 1);
    for (const char* library : {"libffi.so", "libjvm.so", "libjava.so", "libjli.so"}) {
        std::string path = paths[1] + "/" + library;
        if (!dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL)) {
            dprintf(STDERR_FILENO, "JDK load %s: %s\n", library, dlerror());
            _exit(125);
        }
    }
    auto launch = reinterpret_cast<Launch>(dlsym(RTLD_DEFAULT, "JLI_Launch"));
    if (!launch) {
        dprintf(STDERR_FILENO, "JDK launcher: %s\n", dlerror());
        _exit(125);
    }
    std::vector<char*> argv;
    for (auto& argument : arguments) argv.push_back(&argument[0]);
    argv.push_back(nullptr);
    int code = launch(arguments.size(), argv.data(), 0, nullptr, 0, nullptr,
        "17.0.20", "17.0.20", "java", "java", false, true, false, 0);
    fflush(nullptr);
    _exit(code);
}

napi_value Start(napi_env env, napi_callback_info info) {
    size_t count = 7;
    napi_value args[7];
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    std::vector<std::string> paths(6);
    if (count != 7) {
        napi_throw_type_error(env, "JDK_PROCESS", "Expected JDK paths and arguments");
        return nullptr;
    }
    for (size_t i = 0; i < paths.size(); ++i) {
        if (!ReadString(env, args[i], paths[i])) {
            napi_throw_type_error(env, "JDK_PROCESS", "Invalid JDK path");
            return nullptr;
        }
    }
    uint32_t length;
    if (napi_get_array_length(env, args[6], &length) != napi_ok || length == 0) {
        napi_throw_type_error(env, "JDK_PROCESS", "Invalid JDK arguments");
        return nullptr;
    }
    std::vector<std::string> arguments(length);
    for (uint32_t i = 0; i < length; ++i) {
        napi_value value;
        napi_get_element(env, args[6], i, &value);
        if (!ReadString(env, value, arguments[i])) {
            napi_throw_type_error(env, "JDK_PROCESS", "Invalid JDK argument");
            return nullptr;
        }
    }
    int input = open(paths[3].c_str(), O_RDONLY | O_CLOEXEC);
    int output = open(paths[4].c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    int error = open(paths[5].c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (input < 0 || output < 0 || error < 0) {
        int saved = errno;
        if (input >= 0) close(input);
        if (output >= 0) close(output);
        if (error >= 0) close(error);
        errno = saved;
        return Error(env, "JDK streams");
    }
    pid_t parent = getpid();
    pid_t pid = fork();
    if (pid == 0) RunChild(paths, arguments, input, output, error, parent);
    int saved = errno;
    close(input); close(output); close(error);
    if (pid < 0) { errno = saved; return Error(env, "JDK fork"); }
    children.emplace(pid, true);
    napi_value result;
    napi_create_int32(env, pid, &result);
    return result;
}

bool ChildId(napi_env env, napi_callback_info info, int& pid) {
    size_t count = 1;
    napi_value value;
    napi_get_cb_info(env, info, &count, &value, nullptr, nullptr);
    if (count != 1 || napi_get_value_int32(env, value, &pid) != napi_ok || !children.count(pid)) {
        napi_throw_error(env, "JDK_PROCESS", "Unknown JDK child");
        return false;
    }
    return true;
}

napi_value Poll(napi_env env, napi_callback_info info) {
    int pid;
    if (!ChildId(env, info, pid)) return nullptr;
    int status;
    pid_t result;
    do { result = waitpid(pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    if (result < 0) return Error(env, "JDK wait");
    napi_value value;
    if (result == 0) {
        napi_get_null(env, &value);
    } else {
        children.erase(pid);
        int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
        napi_create_int32(env, code, &value);
    }
    return value;
}

napi_value Cancel(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value argument;
    int pid;
    napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr);
    if (count != 1 || napi_get_value_int32(env, argument, &pid) != napi_ok) {
        napi_throw_type_error(env, "JDK_PROCESS", "Invalid JDK child PID");
        return nullptr;
    }
    if (!children.count(pid)) {
        napi_value value;
        napi_get_undefined(env, &value);
        return value;
    }
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) return Error(env, "JDK cancel");
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}
}

void RegisterJdkProcesses(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        {"startJava", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pollJava", nullptr, Poll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelJava", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, 3, properties);
}
