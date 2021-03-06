#!/bin/bash

set -e -u

# Stuart's recommendation to stop lapack-test from failing
ulimit -s 50000

# Fix segfault issue arising from a bug in Linux 2.6.32; we can probably skip
# this patch once we drop support for CentOS/RHEL 6.x. For details, see:
# https://github.com/xianyi/OpenBLAS/wiki/faq#Linux_SEGFAULT
patch < segfaults.patch

# Fix ctest not automatically discovering tests
LDFLAGS=$(echo "${LDFLAGS}" | sed "s/-Wl,--gc-sections//g")

# See this workaround
# ( https://github.com/xianyi/OpenBLAS/issues/818#issuecomment-207365134 ).
export CF="${CFLAGS} -Wno-unused-parameter -Wno-old-style-declaration"
unset CFLAGS

# Silly "if" statement, but it makes things clearer
if [[ ${target_platform} == osx-64 ]]; then
    # No OpenMP on Mac.  We mix gfortran and clang for the macOS build, and we
    # want to avoid mixing their OpenMP implementations until we've done more
    # extensive testing.
    USE_OPENMP="0"

    export CF="$CF -Wl,-rpath,$PREFIX/lib"
    export LAPACK_FFLAGS="${LAPACK_FFLAGS:-} -Wl,-rpath,$PREFIX/lib"
    export FFLAGS="$FFLAGS -Wl,-rpath,$PREFIX/lib"
elif [[ ${target_platform} == linux-* ]]; then
    # GNU OpenMP is not fork-safe.  We disable OpenMP for now, so that
    # downstream packages don't hang as a result.  Conda-forge builds OpenBLAS
    # for Linux using gfortran but uses the LLVM OpenMP implementation at
    # run-time; however, we want to avoid such mixing in the defaults channel
    # until more extensive has been done.
    USE_OPENMP="0"
fi

if [[ "$USE_OPENMP" == "1" ]]; then
    # Run the fork test (as part of `openblas_utest`)
    sed -i.bak 's/test_potrs.o/test_potrs.o test_fork.o/g' utest/Makefile
fi

if [ ! -z "$FFLAGS" ]; then
    # Don't use GNU OpenMP, which is not fork-safe
    export FFLAGS="${FFLAGS/-fopenmp/ }"

    export FFLAGS="${FFLAGS} -frecursive"

    export LAPACK_FFLAGS="${FFLAGS}"
fi

# Because -Wno-missing-include-dirs does not work with gfortran:
[[ -d "${PREFIX}"/include ]] || mkdir "${PREFIX}"/include
[[ -d "${PREFIX}"/lib ]] || mkdir "${PREFIX}"/lib

# Set CPU Target
case "${target_platform}" in
    linux-aarch64)
        TARGET="ARMV8"
        BINARY="64"
        ;;
    linux-ppc64le)
        TARGET="POWER8"
        BINARY="64"
        ;;
    linux-64)
        # Oldest x86/x64 target microarch that has 64-bit extensions
        TARGET="PRESCOTT"
        BINARY="64"
        ;;
    osx-64)
        # Oldest OS X version we support is Mavericks (10.9), which requires a
        # system with at least an Intel Core 2 CPU.
        TARGET="CORE2"
        BINARY="64"
        ;;
esac

# Placeholder for future builds that may include ILP64 variants.
INTERFACE64=0
SYMBOLSUFFIX=""

# Build all CPU targets and allow dynamic configuration
# Build LAPACK.
# Enable threading. This can be controlled to a certain number by
# setting OPENBLAS_NUM_THREADS before loading the library.

# USE_SIMPLE_THREADED_LEVEL3 is necessary to avoid hangs when more than one process uses blas:
#    https://github.com/xianyi/OpenBLAS/issues/1456
#    https://github.com/xianyi/OpenBLAS/issues/294
#    https://github.com/scikit-learn/scikit-learn/issues/636
#USE_SIMPLE_THREADED_LEVEL3=1

make DYNAMIC_ARCH=1 BINARY=${BINARY} NO_LAPACK=0 NO_AFFINITY=1 USE_THREAD=1 NUM_THREADS=128 \
     HOST=${HOST} TARGET=${TARGET} CROSS_SUFFIX="${HOST}-" \
     INTERFACE64=${INTERFACE64} SYMBOLSUFFIX=${SYMBOLSUFFIX} \
     USE_OPENMP="${USE_OPENMP}" CFLAGS="${CF}" FFLAGS="${FFLAGS}"

# BLAS tests are now run as part of build process; LAPACK tests still need to
# be separately built and run.
#OPENBLAS_NUM_THREADS=${CPU_COUNT} CFLAGS="${CF}" FFLAGS="${FFLAGS}" make test
OPENBLAS_NUM_THREADS=${CPU_COUNT} CFLAGS="${CF}" FFLAGS="${FFLAGS}" make lapack-test

CFLAGS="${CF}" FFLAGS="${FFLAGS}" make install PREFIX="${PREFIX}"

# As OpenBLAS, now will have all symbols that BLAS, CBLAS or LAPACK have,
# create libraries with the standard names that are linked back to
# OpenBLAS. This will make it easier for packages that are looking for them.
for arg in blas cblas lapack; do
  ln -fs "${PREFIX}"/lib/pkgconfig/openblas.pc "${PREFIX}"/lib/pkgconfig/$arg.pc
  ln -fs "${PREFIX}"/lib/libopenblas.a "${PREFIX}"/lib/lib$arg.a
  ln -fs "${PREFIX}"/lib/libopenblas$SHLIB_EXT "${PREFIX}"/lib/lib$arg$SHLIB_EXT
done

if [[ ${target_platform} == osx-64 ]]; then
  # Needs to fix the install name of the dylib so that the downstream projects will link
  # to libopenblas.dylib instead of libopenblasp-r0.2.20.dylib
  # In linux, SONAME is libopenblas.so.0 instead of libopenblasp-r0.2.20.so, so no change needed
  test -f ${PREFIX}/lib/libopenblas.0.dylib || \
      ln -s ${PREFIX}/lib/libopenblas.dylib ${PREFIX}/lib/libopenblas.0.dylib
  ${INSTALL_NAME_TOOL} -id "${PREFIX}"/lib/libopenblas.0.dylib "${PREFIX}"/lib/libopenblas.dylib
fi

cp "${RECIPE_DIR}"/site.cfg "${PREFIX}"/site.cfg
echo library_dirs = ${PREFIX}/lib >> "${PREFIX}"/site.cfg
echo include_dirs = ${PREFIX}/include >> "${PREFIX}"/site.cfg
echo runtime_include_dirs = ${PREFIX}/lib >> "${PREFIX}"/site.cfg
