#!/usr/bin/env bash

set -euxo pipefail

num_commits=$( git rev-list --count HEAD )

top_dir=$PWD/clang-llvm
mkdir -p "$top_dir"
cd "$top_dir"

tools_bin_dir="$top_dir/bin"
mkdir -p "$tools_bin_dir"
export PATH="$tools_bin_dir:$PATH"

if ! command -v hub; then
  # hub will get installed into the bin directory inside of the current directory
  curl -fsSL https://github.com/github/hub/raw/master/script/get | bash -s 2.14.1
  ls -l "$tools_bin_dir"
fi

if ! command -v ninja; then
  git clone --depth 1 --branch release https://github.com/ninja-build/ninja
  (
    cd ninja
    ./bootstrap.py
    cp ninja "$tools_bin_dir"
  )
fi

llvm_checkout_dir="$top_dir/llvm-project"
git clone --depth 1 https://github.com/llvm/llvm-project.git "$llvm_checkout_dir" 2>&1 | \
  grep -Ev 'Updating files:'
llvm_sha1=$( cd "$llvm_checkout_dir" | git rev-parse HEAD )
tag="llvm-$llvm_sha1-v$num_commits"
build_dir_basename="clang-build"
build_dir="$top_dir/$build_dir_basename"
mkdir -p "$build_dir"
cd "$build_dir"

install_dir_basename="clang-installed"
install_dir="$top_dir/$install_dir_basename"
mkdir -p "$install_dir"

# Flags: https://llvm.org/docs/CMake.html
cmake -G Ninja "$llvm_checkout_dir/llvm" \
  -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra" \
  -DLLVM_BUILD_TESTS=ON \
  -DCMAKE_INSTALL_PREFIX="$install_dir" \
  -DLLVM_TARGETS_TO_BUILD="X86" \
  -DLLVM_BUILD_EXAMPLES=ON

ninja

test_results="$top_dir/test_results.log"

set +e
(
  test_exit_code=0
  set +e
  # Test LLVM only.
  ninja check
  if [[ $? -ne 0 ]]; then
    test_exit_code=$?
  fi

  # Test Clang only.
  ninja clang-test
  if [[ $? -ne 0 ]]; then
    test_exit_code=$?
  fi

  exit $test_exit_code
) 2>&1 | tee "$test_results"
test_exit_code=$?
set -e
echo >>"$test_results"
echo "Tests exited with code $test_exit_code" >>"$test_results"

mkdir -p "$install_dir"
ninja install

cp "$test_results" "$build_dir"
cp "$test_results" "$install_dir"

cd "$top_dir"

build_archive="$build_dir_basename-$llvm_sha1.zip"
zip "$build_archive" "$build_dir_basename"

installed_archive="$install_dir_basename-$llvm_sha1.zip"
zip "$installed_archive" "$install_dir_basename"

hub release create "$tag" \
  -m "Release for LLVM commit $llvm_sha1" \
  -a "$build_archive" \
  -a "$installed_archive"
