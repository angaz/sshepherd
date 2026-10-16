#include "engine.hpp"
#include <jni.h>
#include <memory>
#include <stdexcept>
#include <mutex>
#include <unordered_map>

namespace {
std::mutex mutex;
std::unordered_map<jlong, std::unique_ptr<Engine>> terminals;
jlong nextId = 1;
Engine& get(jlong id) {
    auto found = terminals.find(id);
    if (found == terminals.end()) throw std::runtime_error("Terminal is closed");
    return *found->second;
}
void error(JNIEnv* env, const char* message) {
    if (env->ExceptionCheck()) return;
    auto type = env->FindClass("java/lang/IllegalStateException");
    if (type) { env->ThrowNew(type, message); env->DeleteLocalRef(type); }
}
std::vector<uint8_t> input(JNIEnv* env, jbyteArray array, size_t limit) {
    if (!array) throw std::invalid_argument("Missing byte array");
    auto len = env->GetArrayLength(array);
    if (len < 0 || size_t(len) > limit) throw std::invalid_argument("Input exceeds limit");
    std::vector<uint8_t> bytes(len);
    env->GetByteArrayRegion(array, 0, len, reinterpret_cast<jbyte*>(bytes.data()));
    if (env->ExceptionCheck()) throw std::runtime_error("Cannot read Java array");
    return bytes;
}
jbyteArray output(JNIEnv* env, const std::vector<uint8_t>& bytes) {
    auto array = env->NewByteArray(jsize(bytes.size()));
    if (array && !bytes.empty()) env->SetByteArrayRegion(array, 0, jsize(bytes.size()), reinterpret_cast<const jbyte*>(bytes.data()));
    return array;
}
}
#define JNI_METHOD(name) extern "C" JNIEXPORT name JNICALL
#define GUARD(body, fallback) try { std::lock_guard<std::mutex> lock(mutex); body } catch (const std::exception& e) { error(env, e.what()); return fallback; } catch (...) { error(env, "Native terminal failure"); return fallback; }

JNI_METHOD(jlong) Java_io_angaz_sshepherd_GhosttyNative_create(JNIEnv* env, jclass, jint cols, jint rows) {
    GUARD(auto terminal = std::make_unique<Engine>(cols, rows); auto id = nextId++; terminals.emplace(id, std::move(terminal)); return id;, 0)
}
JNI_METHOD(void) Java_io_angaz_sshepherd_GhosttyNative_destroy(JNIEnv* env, jclass, jlong id) {
    GUARD(terminals.erase(id); return;, )
}
JNI_METHOD(void) Java_io_angaz_sshepherd_GhosttyNative_write(JNIEnv* env, jclass, jlong id, jbyteArray array) {
    GUARD(auto bytes = input(env, array, 1024 * 1024); get(id).write(bytes.data(), bytes.size()); return;, )
}
JNI_METHOD(void) Java_io_angaz_sshepherd_GhosttyNative_resize(JNIEnv* env, jclass, jlong id, jint cols, jint rows, jint width, jint height) {
    GUARD(get(id).resize(cols, rows, width, height); return;, )
}
JNI_METHOD(jbyteArray) Java_io_angaz_sshepherd_GhosttyNative_frame(JNIEnv* env, jclass, jlong id) {
    GUARD(return output(env, get(id).frame());, nullptr)
}
JNI_METHOD(jbyteArray) Java_io_angaz_sshepherd_GhosttyNative_hyperlink(JNIEnv* env, jclass, jlong id, jint x, jint y) {
    GUARD(return output(env, get(id).hyperlink(x, y));, nullptr)
}
JNI_METHOD(jbyteArray) Java_io_angaz_sshepherd_GhosttyNative_replies(JNIEnv* env, jclass, jlong id) {
    GUARD(return output(env, get(id).takeReplies());, nullptr)
}
JNI_METHOD(jbyteArray) Java_io_angaz_sshepherd_GhosttyNative_clipboard(JNIEnv* env, jclass, jlong id) {
    GUARD(auto value = get(id).takeClipboard(); return value ? output(env, *value) : nullptr;, nullptr)
}
JNI_METHOD(jbyteArray) Java_io_angaz_sshepherd_GhosttyNative_key(JNIEnv* env, jclass, jlong id, jint code, jint mods, jint consumed, jint action, jbyteArray text) {
    GUARD(auto bytes = input(env, text, 64); return output(env, get(id).key(code, mods, action, std::string(bytes.begin(), bytes.end()), consumed));, nullptr)
}
JNI_METHOD(jbyteArray) Java_io_angaz_sshepherd_GhosttyNative_mouse(JNIEnv* env, jclass, jlong id, jint action, jint button, jdouble x, jdouble y, jint mods) {
    GUARD(return output(env, get(id).mouse(action, button, x, y, mods));, nullptr)
}
JNI_METHOD(jboolean) Java_io_angaz_sshepherd_GhosttyNative_mode(JNIEnv* env, jclass, jlong id, jint number) {
    GUARD(return get(id).mode(number);, false)
}
