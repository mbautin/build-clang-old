#!/usr/bin/env bash

set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Command expected" >&2
  exit 1
fi
command=$1
if [[ $command != "build" && $comamnd != "upload" ]]; then
  echo "Either 'build' or 'upload' expected" >&2
  exit 1
fi

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

if [[ -z ${GITHUB_TOKEN:-} ]]; then
  echo "GITHUB_TOKEN is not set. I won't be able to publish the release." >&2
  exit 1
fi

if ! command -v ninja; then
  echo "::group::Installing Ninja"
  git clone --depth 1 --branch release https://github.com/ninja-build/ninja
  (
    cd ninja
    ./bootstrap.py
    cp ninja "$tools_bin_dir"
  )
  echo "::endgroup::"
fi

echo "::group::Cloning LLVM code"
llvm_checkout_dir="$top_dir/llvm-project"
git clone --depth 1 https://github.com/llvm/llvm-project.git "$llvm_checkout_dir" 2>&1 | \
  grep -Ev 'Updating files:'
llvm_sha1=$( cd "$llvm_checkout_dir" | git rev-parse HEAD )
echo "::endgroup::"

tag="llvm-$llvm_sha1-$GITHUB_RUN_ID-$GITHUB_RUN_NUMBER"
echo "Will use this tag for the release: $tag"
build_dir_basename="clang-build"
build_dir="$top_dir/$build_dir_basename"
mkdir -p "$build_dir"
echo "Build directory: $build_dir"

install_dir_basename="clang-installed"
install_dir="$top_dir/$install_dir_basename"
mkdir -p "$install_dir"
echo "Install directory: $install_dir"

if [[ $command == "build" ]]; then
  # Flags: https://llvm.org/docs/CMake.html

  cd "$build_dir"
  echo "::group::Run CMake"
  cmake \
    -G Ninja \
    "$llvm_checkout_dir/llvm" \
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra" \
    -DLLVM_BUILD_TESTS=ON \
    -DCMAKE_INSTALL_PREFIX="$install_dir" \
    -DLLVM_TARGETS_TO_BUILD="X86" \
    -DLLVM_BUILD_EXAMPLES=ON
  echo "::endgroup::"

  echo "::group::Build LLVM and Clang"
  ninja
  echo "::endgroup"

  echo :":group::Run tests"
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
  echo "::endgroup::"

  echo "::group::Install LLVM and Clang"
  mkdir -p "$install_dir"
  ninja install
  echo "::endgroup"

  cp "$test_results" "$build_dir"
  cp "$test_results" "$install_dir"
fi

cd "$top_dir"

if [[ $command == "build" ]]; then
  echo "Current directory: $top_dir"
  echo "Creating archives"
fi

build_archive="$build_dir_basename-$llvm_sha1.zip"
if [[ $command == "build" ]]; then
  ( set -x; zip -r "$build_archive" "$build_dir_basename" )
fi

installed_archive="$install_dir_basename-$llvm_sha1.zip"
if [[ $command == "build" ]]; then
  ( set -x; zip -r "$installed_archive" "$install_dir_basename" )
fi

if [[ $command == "upload" ]]; then
  set -x
  hub release create "$tag" \
    -m "Release for LLVM commit $llvm_sha1" \
    -a "$build_archive" \
    -a "$installed_archive"
fi
