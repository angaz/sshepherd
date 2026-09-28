#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/prepare-ghostty.sh
root=$PWD
(cd .deps/libghostty-vt && zig build -Demit-lib-vt -Dsimd=false -Doptimize=ReleaseFast --prefix "$root/.deps/ghostty-host")
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Wno-missing-field-initializers \
  -I.deps/libghostty-vt/include terminal/engine.cpp terminal/engine_test.cpp \
  .deps/ghostty-host/lib/libghostty-vt.a -lpthread -ldl -lm -o .deps/terminal-test
.deps/terminal-test
: "${JAVA_HOME:?Set JAVA_HOME for the JNI integration test}"
case "$(uname -s)" in
  Linux) jni_host=linux; extension=so;;
  Darwin) jni_host=darwin; extension=dylib;;
esac
"${CXX:-c++}" -std=c++17 -O2 -shared -fPIC -I.deps/libghostty-vt/include \
  -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/$jni_host" terminal/engine.cpp terminal/jni.cpp \
  .deps/ghostty-host/lib/libghostty-vt.a -lpthread -ldl -lm -o ".deps/libsshepherd_terminal.$extension"
mkdir -p .deps/jni-test
"$JAVA_HOME/bin/javac" -d .deps/jni-test terminal/jvm/io/angaz/sshepherd/GhosttyNative.java
"$JAVA_HOME/bin/java" -Djava.library.path=.deps -cp .deps/jni-test io.angaz.sshepherd.GhosttyNative
