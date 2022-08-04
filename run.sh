#!/bin/bash

set -euxo pipefail

hosts=mpi014,mpi016

#--------------

# Libfabric

lf_top=$HOME/libfabric-releases
lf=libfabric-1.12.1
lf_prefix=$lf_top/$lf/install

# This is where we'll move the libfabric install as part of the test
lf_prefix_alternate=$lf_top/$lf/install-alternate

build_libfabric() {
    cd $lf_top
    rm -rf $lf
    # Tarball was previously downloaded
    tar xf $lf.tar.bz2

    cd $lf
    ./configure \
        --prefix=$lf_prefix \
        --enable-usnic \
        --enable-debug |& tee config.out
    make -j 32 |& tee make.out
    make install |& tee install.out
}

#--------------

# Open MPI

ompi_git=$HOME/git/o3
ompi_prefix=$HOME/bogus

build_ompi() {
    rm -rf $ompi_prefix

    # On master branch
    cd $ompi_git
    ./contrib/git-clean.sh

    ./autogen.pl |& tee auto.out
    ./configure \
        --prefix=$ompi_prefix \
        --with-usnic \
        --with-libfabric=$lf_prefix \
        --enable-mpirun-prefix-by-default \
        --enable-debug \
        --enable-mem-debug \
        --enable-mem-profile \
        --disable-mpi-fortran |& tee config.out
    make -j 32 |& tee make.out
    make install |& tee install.out

    cd examples
    make
}

#--------------

# Sanity checks on the environment

sanity_checks_env() {
    set +e

    # LD_LIBRARY_PATH should contain $lf_prefix/lib
    out=`echo $LD_LIBRARY_PATH | grep $lf_prefix/lib`
    if test -z "$out"; then
        echo "Barf: LD_LIBRARY_PATH does not contain $lf_prefix/lib"
        exit 1
    fi

    # LD_LIBRARY_PATH should NOT contain $lf_prefix_alternate/lib
    out=`echo $LD_LIBRARY_PATH | grep $lf_prefix_alternate/lib`
    if test -n "$out"; then
        echo "Barf: LD_LIBRARY_PATH already contains $lf_prefix_alternate/lib"
        exit 1
    fi

    # LD_LIBRARY_PATH should contain $ompi_prefix/lib
    out=`echo $LD_LIBRARY_PATH | grep $ompi_prefix/lib`
    if test -z "$out"; then
        echo "Barf: LD_LIBRARY_PATH does not contain $ompi_prefix/lib"
        exit 1
    fi

    # PATH should contain $ompi_prefix/bin
    out=`echo $PATH | grep $ompi_prefix/bin`
    if test -z "$out"; then
        echo "Barf: PATH does not contain $ompi_prefix/bin"
        exit 1
    fi

    set -e
}

#--------------

# Sanity checks on tests

sanity_checks_tests() {
    ldd $ompi_git/examples/ring_c
    readelf -d $ompi_git/examples/ring_c

    ldd $ompi_prefix/bin/mpirun
    readelf -d $ompi_prefix/bin/mpirun

    ldd $ompi_prefix/lib/libopen-pal.so
    readelf -d $ompi_prefix/lib/libopen-pal.so
}

#--------------

run_tests() {
    set +e

    # Just for giggles
    ompi_info | grep usnic

    # Prove that we're spanning 2 hosts
    mpirun --host $hosts --mca btl usnic,sm,self -np 2 hostname

    # Double check our local and remote LD_LIBRARY_PATH
    mpirun --host $hosts --mca btl usnic,sm,self -np 2 env | grep LD_LIBRARY_PATH

    # Run ring with usnic across 2 hosts, which requires libfabric
    # (and since mpirun links to libopen-pal, mpirun requires
    # libfabric, too)
    mpirun --host $hosts --mca btl usnic,sm,self -np 2 $ompi_git/examples/ring_c

    set -e
}

#--------------

# Helper to move the libfabric install to its alternate location, and
# then ensure that all NFS clients have updated their cache to reflect
# this change.

move_libfabric() {
    mv $lf_prefix $lf_prefix_alternate

    # Ensure that my ancient/slow NFS client has updated its cache on all
    # the nodes
    set +e
    IFS_save=$IFS
    IFS=,
    for host in $hosts; do
        ssh $host ls -l $lf_prefix
        ssh $host ls -l $lf_prefix_alternate
        ssh $host ls -l $lf_prefix
    done
    set -e

    IFS=$IFS_save
}

#--------------
# main
#--------------

build_libfabric
build_ompi
sanity_checks_env
sanity_checks_tests

echo "=== Running tests with libfabric in place"
run_tests

echo "=== Running tests with libfabric moved, but not updating LD_LIBRARY_PATH"
move_libfabric
run_tests

echo "=== Running tests with libfabric moved, and updated LD_LIBRARY_PATH"
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$lf_prefix_alternate/lib"
run_tests
