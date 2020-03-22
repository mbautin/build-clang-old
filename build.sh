#!/usr/bin/env bash

set -euxo pipefail

top_dir=$PWD/clang-llvm
mkdir -p "$top_dir"
cd "$top_dir"

tools_bin_dir="$top_dir/bin"
mkdir -p "$tools_bin_dir"
export PATH="$tools_bin_dir:$PATH"

if ! command -v ninja; then
  git clone https://github.com/ninja-build/ninja
  (
    cd ninja
    git checkout release
    ./bootstrap.py
    cp ninja "$tools_bin_dir"
  )
fi

llvm_checkout_dir="$top_dir/llvm-project"
git clone https://github.com/llvm/llvm-project.git "$llvm_checkout_dir"
build_dir="$top_dir/build"
mkdir -p "$build_dir"
cd "$build_dir"
install_dir="$top_dir/installed"
cmake -G Ninja "$llvm_checkout_dir/llvm" \
  -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra" \
  -DLLVM_BUILD_TESTS=ON \
  -DCMAKE_INSTALL_PREFIX="$install_dir"

ninja
# Test LLVM only.
ninja check
# Test Clang only.
ninja clang-test
ninja install


