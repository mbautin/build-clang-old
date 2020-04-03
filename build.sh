#!/usr/bin/env bash

set -euo pipefail

start_group() {
  echo "::group::$*"
}

end_group() {
  echo "::endgroup::$*"
}

if [[ $# -eq 0 ]]; then
  echo "step expected: 'build' or 'upload'" >&2
  exit 1
fi
step=$1
if [[ ! $step =~ ^(build|upload) ]]; then
  echo "Either 'build' or 'upload' step expected" >&2
  exit 1
fi

top_dir=$HOME/clang-llvm
mkdir -p "$top_dir"
cd "$top_dir"

build_dir_basename="clang-build"
build_dir="$top_dir/$build_dir_basename"
mkdir -p "$build_dir"

install_dir_basename="clang-installed"
install_dir="$top_dir/$install_dir_basename"
mkdir -p "$install_dir"

llvm_checkout_dir="$top_dir/llvm-project"

if [[ "$step" == "upload" && -z ${GITHUB_TOKEN:-} ]]; then
  echo "GITHUB_TOKEN is not set. I won't be able to publish the release." >&2
  exit 1
fi

start_group "Cloning LLVM code if not already done"
if [[ ! -d $llvm_checkout_dir/.git ]]; then
  git clone --depth 1 https://github.com/llvm/llvm-project.git "$llvm_checkout_dir" 2>&1 | \
    grep -Ev 'Updating files:'
fi
llvm_sha1=$( cd "$llvm_checkout_dir" && git rev-parse HEAD )
end_group

if [[ $step == "build" ]]; then
  if ! command -v ninja; then
    start_group "Installing Ninja"
    git clone --depth 1 --branch release https://github.com/ninja-build/ninja
    (
      cd ninja
      ./bootstrap.py
      sudo cp ninja /usr/local/bin
    )
    end_group
  fi

  # Flags: https://llvm.org/docs/CMake.html

  cd "$build_dir"
  start_group "Run CMake"
  cmake \
    -G Ninja \
    "$llvm_checkout_dir/llvm" \
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra" \
    -DLLVM_BUILD_TESTS=ON \
    -DCMAKE_INSTALL_PREFIX="$install_dir" \
    -DLLVM_TARGETS_TO_BUILD="X86" \
    -DLLVM_BUILD_EXAMPLES=ON
  end_group

  start_group "Build LLVM and Clang"
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
  end_group

  start_group "Install LLVM and Clang"
  mkdir -p "$install_dir"
  ninja install
  echo "::endgroup"

  cp "$test_results" "$build_dir"
fi

if [[ $step == "upload" ]]; then
  tag="llvm-$llvm_sha1-$GITHUB_RUN_ID-$GITHUB_RUN_NUMBER"

  build_archive="$build_dir_basename-$llvm_sha1.zip"
  ( set -x; zip -r "$build_archive" "$build_dir_basename" )

  installed_archive="$install_dir_basename-$llvm_sha1.zip"
  ( set -x; zip -r "$installed_archive" "$install_dir_basename" )

  set -x
  hub release create "$tag" \
    -m "Release for LLVM commit $llvm_sha1" \
    -a "$build_archive" \
    -a "$installed_archive"
fi
