#!/usr/bin/env bash

set -euo pipefail

start_group() {
  echo "::group::$*"
}

end_group() {
  echo "::endgroup::$*"
}

fatal() {
  echo "$@" >&2
  exit 1 
}

initial_dir=$PWD

step=${1:-}
if [[ ! $step =~ ^(build|upload|zip) ]]; then
  fatal "Either 'build' or 'upload' step expected, got: $step"
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

  (
    cd "$build_dir"
    start_group "Run CMake"
    cmake \
      -G Ninja \
      "$llvm_checkout_dir/llvm" \
      -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra" \
      -DLLVM_BUILD_TESTS=ON \
      -DCMAKE_INSTALL_PREFIX="$install_dir" \
      -DLLVM_TARGETS_TO_BUILD="X86" \
      -DLLVM_BUILD_EXAMPLES=ON \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    end_group

    start_group "Build LLVM and Clang"
    ninja
    end_group

    start_group "Running tests"
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

    start_group "Install LLVM and Clang into $install_dir"
    mkdir -p "$install_dir"
    ninja install
    end_group

    cp "$test_results" "$build_dir"
  )
fi

if [[ -n ${GITHUB_RUN_ID:-} && -n ${GITHUB_RUN_NUMBER:-} ]]; then
  tag="llvm-$llvm_sha1-$GITHUB_RUN_ID-$GITHUB_RUN_NUMBER"
else
  tag="llvm-$llvm_sha1"
fi

build_archive="$build_dir_basename-$tag.zip"
installed_archive="$install_dir_basename-$tag.zip"

if [[ $step == "zip" ]]; then
  start_group "Creating $build_archive"
  ( set -x; zip -qr "$build_archive" "$build_dir_basename" )
  end_group
  
  start_group "Creating $installed_archive"
  ( set -x; zip -qr "$installed_archive" "$install_dir_basename" )
  end_group
fi

if [[ $step == "upload" ]]; then
  cd "$initial_dir"
  set -x
  hub release create "$tag" \
    -m "Release for LLVM commit $llvm_sha1" \
    -a "$build_archive" \
    -a "$installed_archive"
fi
