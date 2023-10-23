#!/bin/bash
#
# $Id$
#
# Copyright 2016-2017 Quantcast Corporation. All rights reserved.
#
# This file is part of Quantcast File System.
#
# Licensed under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied. See the License for the specific language governing
# permissions and limitations under the License.

################################################################################
# The following is executed on .travis.yml's script section
################################################################################

set -ex

DEPS_UBUNTU='g++ cmake git libboost-regex-dev libkrb5-dev libssl-dev'
DEPS_UBUNTU=$DEPS_UBUNTU' libfuse-dev default-jdk zlib1g-dev unzip maven sudo'
DEPS_UBUNTU=$DEPS_UBUNTU' passwd curl openssl fuse gdb'
DEPS_UBUNTU22=$DEPS_UBUNTU' golang-go'
DEPS_UBUNTU=$DEPS_UBUNTU' python-dev'
DEPS_DEBIAN=$DEPS_UBUNTU

DEPS_CENTOS='gcc-c++ make git boost-devel krb5-devel'
DEPS_CENTOS=$DEPS_CENTOS' fuse-devel java-openjdk java-devel'
DEPS_CENTOS=$DEPS_CENTOS' libuuid-devel curl unzip sudo which openssl fuse gdb'

DEPS_CENTOS5=$DEPS_CENTOS' cmake28 openssl101e openssl101e-devel'
DEPS_CENTOS=$DEPS_CENTOS' openssl-devel cmake'
DEPS_CENTOS8=$DEPS_CENTOS' diffutils hostname'

MYMVN_URL='https://dlcdn.apache.org/maven/maven-3/3.9.5/binaries/apache-maven-3.9.5-bin.tar.gz'

MYTMPDIR='.tmp'
MYCODECOV="$MYTMPDIR/codecov.sh"
MYCENTOSEPEL_RPM="$MYTMPDIR/epel-release-latest.rpm"
MYMVNTAR="$MYTMPDIR/$(basename "$MYMVN_URL")"
MYDOCKERBUILDDEBUGFILENAME="$MYTMPDIR/docker_build_debug"

MYCMAKE='cmake'

MYCMAKE_OPTIONS=''
MYCMAKE_OPTIONS=$MYCMAKE_OPTIONS' -D QFS_EXTRA_CXX_OPTIONS=-Werror'
MYCMAKE_OPTIONS=$MYCMAKE_OPTIONS' -D QFS_EXTRA_C_OPTIONS=-Werror'

MYCMAKE_CENTOS5='cmake28'
MYCMAKE_OPTIONS_CENTOS5=$MYCMAKE_OPTIONS' -D _OPENSSL_INCLUDEDIR=/usr/include/openssl101e'
MYCMAKE_OPTIONS_CENTOS5=$MYCMAKE_OPTIONS_CENTOS5' -D _OPENSSL_LIBDIR=/usr/lib64/openssl101e'

MYQFSHADOOP_VERSIONS_UBUNTU1404_CENTOS6='0.23.4 0.23.11  1.0.4  1.1.2  2.5.1  2.7.2'
MYQFSHADOOP_VERSIONS_UBUNTU1804='1.0.4  1.1.2  2.7.2  2.7.7  2.8.5  2.9.2  2.10.1  3.1.4  3.2.2  3.3.1'
MYQFSHADOOP_VERSIONS_CENTOS5='0.23.4  0.23.11  1.0.4  1.1.2  2.5.1'

MYBUILD_TYPE='release'

set_sudo()
{
    if [ x"$(id -u)" = x'0' ]; then
        MYSUDO=
        MYUSER=
        if [ $# -gt 0 ]; then
            if [ x"$1" = x'root' ]; then
                true
            else
                MYUSER=$1
            fi
        fi
        if [ x"$MYUSER" = x ]; then
            MYSU=
        else
            MYSU="sudo -H -u $MYUSER"
        fi
    else
        MYSUDO='sudo'
        MYSU=
        MYUSER=
    fi
}

cores_show_stack_traces()
{
    gdb -version > /dev/null || return 0
    MYGDBCMDS=`mktemp`
    cat > "$MYGDBCMDS" << EOF
bt
thread apply all bt
EOF
    find ${1+"$@"} -type f -name core\* -print \
    | while read MYCORE; do
        MYEXECUTABLE=$(gdb -batch -c  "$MYCORE" 2>/dev/null \
            | sed -ne 's/^Core was generated by `\([^ ]*\).*$/\1/p')
        echo "================== $MYEXECUTABLE $MYCORE ===="
        gdb -batch "$MYEXECUTABLE" -c "$MYCORE" -x "$MYGDBCMDS" \
            2>/dev/null || true
        echo "------------------ $MYEXECUTABLE $MYCORE ----"
    done
    rm "$MYGDBCMDS"
    return 0
}

tail_logs_and_exit()
{
    MYQFSTEST_DIR="build/$MYBUILD_TYPE/qfstest"
    if [ -d "$MYQFSTEST_DIR" ]; then
        cores_show_stack_traces "$MYQFSTEST_DIR"
        find "$MYQFSTEST_DIR" -type f -name '*.log' -print0 \
        | xargs -0  tail -n 100
    fi
    while [ -e "$MYDOCKERBUILDDEBUGFILENAME" ]; do
        echo 'sleeping for 10 sec.'
        sleep 10
    done
    exit 1
}

do_build()
{
    if [ x"$MYBUILD_TYPE" = x'debug' ]; then
        MYCMAKE_OPTIONS=$MYCMAKE_OPTIONS' -D CMAKE_BUILD_TYPE=Debug'
    else
        MYCMAKE_OPTIONS=$MYCMAKE_OPTIONS' -D CMAKE_BUILD_TYPE=RelWithDebInfo'
    fi
    sync || true
    $MYSU make ${1+"$@"} \
        BUILD_TYPE="$MYBUILD_TYPE" \
        CMAKE="$MYCMAKE" \
        CMAKE_OPTIONS="$MYCMAKE_OPTIONS" \
        JAVA_BUILD_OPTIONS='-r 5' \
        test tarball \
    || tail_logs_and_exit
}

do_build_linux()
{
    MYMAKEOPT='-j 2'
    if [ -r /proc/cpuinfo ]; then
        cat /proc/cpuinfo
        MYCCNT=`grep -c -w processor /proc/cpuinfo`
        if [ $MYCCNT -gt 2 ]; then
            MYMAKEOPT="-j $MYCCNT"
        fi
    fi
    if [ -r "$MYCODECOV" ]; then
        MYCMAKE_OPTIONS="$MYCMAKE_OPTIONS -D ENABLE_COVERAGE=ON"
    fi
    MYMAKEOPT="$MYMAKEOPT --no-print-directory"
    df -h || true
    do_build ${1+"$@"} $MYMAKEOPT
    if [ -r "$MYCODECOV" ]; then
        /bin/bash "$MYCODECOV"
    fi
}

init_codecov()
{
    # Run code coverage in docker
    # Pass travis env vars to code coverage.
    mkdir -p  "$MYTMPDIR"
    {
        env | grep -E '^(TRAVIS|CI|GITHUB)' | sed \
            -e "s/'/'\\\''/g"  \
            -e "s/=/=\'/" \
            -e 's/$/'"'/" \
            -e 's/^/export /'
        echo 'curl -s https://codecov.io/bash | /bin/bash'
    } > "$MYCODECOV"
}

install_maven()
{
    if [ -f "$MYMVNTAR" ]; then
        $MYSUDO tar -xf "$MYMVNTAR" -C '/usr/local'
        # Set up PATH and links
        (
            cd '/usr/local'
            $MYSUDO ln -snf "$(basename "$MYMVNTAR" '-bin.tar.gz')" maven
        )
        M2_HOME='/usr/local/maven'
        MYPATH="${M2_HOME}/bin${MYPATH+:${MYPATH}}"
    fi
}

build_ubuntu()
{
    if [ x"$1" = x'22.04' ]; then
        MYDEPS=$DEPS_UBUNTU22
    else
        MYDEPS=$DEPS_UBUNTU
    fi
    $MYSUDO apt-key update
    $MYSUDO apt-get update
    $MYSUDO /bin/bash -c \
        "DEBIAN_FRONTEND='noninteractive' apt-get install -y $MYDEPS"
    if [ x"$1" = x'18.04' -o x"$1" = x'20.04' -o x"$1" = x'22.04' ]; then
        QFSHADOOP_VERSIONS=$MYQFSHADOOP_VERSIONS_UBUNTU1804
    fi
    if [ x"$1" = x'14.04' ]; then
        install_maven
        QFSHADOOP_VERSIONS=$MYQFSHADOOP_VERSIONS_UBUNTU1404_CENTOS6
    fi
    do_build_linux \
        ${MYPATH+PATH="${MYPATH}:${PATH}"} \
        ${M2_HOME+M2_HOME="$M2_HOME"} \
        ${QFSHADOOP_VERSIONS+QFSHADOOP_VERSIONS="$QFSHADOOP_VERSIONS"}
}

build_ubuntu32()
{
    build_ubuntu
}

build_debian()
{
    if [ x"$1" = x'9' ]; then
        true
    else
        QFSHADOOP_VERSIONS=$MYQFSHADOOP_VERSIONS_UBUNTU1804
    fi
    build_ubuntu
}

build_centos()
{
    if [ x"$1" = x'5' ]; then
        # Centos 5 EOL, use vault for now.
        sed -i 's/enabled=1/enabled=0/' \
            /etc/yum/pluginconf.d/fastestmirror.conf
        sed -i 's/mirrorlist/#mirrorlist/' \
            /etc/yum.repos.d/*.repo
        sed -i 's/#\(baseurl.*\)mirror.centos.org\/centos\/\$releasever\//\1vault.centos.org\/5.11\//' \
            /etc/yum.repos.d/*.repo
    elif [ x"$1" = x'6' ]; then
        # Centos 6 EOL, use vault for now.
        sed -i 's/enabled=1/enabled=0/' \
            /etc/yum/pluginconf.d/fastestmirror.conf
        sed -i 's/mirrorlist/#mirrorlist/' \
            /etc/yum.repos.d/*.repo
        sed -i 's/#\(baseurl.*\)mirror.centos.org\/centos\/\$releasever\//\1vault.centos.org\/6.10\//' \
            /etc/yum.repos.d/*.repo
    else
        $MYSUDO yum update -y
    fi
    if [ -f "$MYCENTOSEPEL_RPM" ]; then
        $MYSUDO rpm -Uvh "$MYCENTOSEPEL_RPM"
    fi
    eval MYDEPS='${DEPS_CENTOS'"$1"'-$DEPS_CENTOS}'
    $MYSUDO yum install -y $MYDEPS
    MYPATH=$PATH
    # CentOS doesn't package maven directly so we have to install it manually
    install_maven
    if [ x"$1" = x'5' ]; then
        # Force build and test to use openssl101e.
        # Add Kerberos binaries dir to path to make krb5-config available.
        if [ x"$MYUSER" = x ]; then
            MYBINDIR="$HOME/local/openssl101e/bin"
        else
            MYBINDIR='/usr/local/openssl101e/bin'
        fi
        mkdir -p "$MYBINDIR"
        ln -snf "`which openssl101e`" "$MYBINDIR/openssl"
        MYPATH="$MYBINDIR:$MYPATH:/usr/kerberos/bin"
        MYCMAKE_OPTIONS=$MYCMAKE_OPTIONS_CENTOS5
        MYCMAKE=$MYCMAKE_CENTOS5
        QFSHADOOP_VERSIONS=$MYQFSHADOOP_VERSIONS_CENTOS5
    elif [ x"$1" = x'6' ]; then
        QFSHADOOP_VERSIONS=$MYQFSHADOOP_VERSIONS_UBUNTU1404_CENTOS6
    fi
    if [ x"$1" = x'6' ]; then
        # Remove jre 1.8 as jdk is only 1.7
        alternatives --remove java \
            /usr/lib/jvm/jre-1.8.0-openjdk.x86_64/bin/java
    fi
    if [ x"$1" = x'7' ]; then
        # CentOS7 has the distro information in /etc/redhat-release
        $MYSUDO /bin/bash -c \
            "cut /etc/redhat-release -d' ' --fields=1,3,4 > /etc/issue"
    fi
    do_build_linux PATH="$MYPATH" ${M2_HOME+M2_HOME="$M2_HOME"} \
        ${QFSHADOOP_VERSIONS+QFSHADOOP_VERSIONS="$QFSHADOOP_VERSIONS"}
}

set_build_type()
{
    if [ x"$1" = x ]; then
        true
    else
        MYBUILD_TYPE=$1
    fi
}

if [ $# -eq 5 -a x"$1" = x'build' ]; then
    set_build_type "$4"
    set_sudo "$5"
    if [ x"$MYUSER" = x ]; then
        true
    else
        # Create regular user to run the build and test under it.
        id -u "$MYUSER" >/dev/null 2>&1 || useradd -m "$MYUSER"
        chown -R "$MYUSER" .
    fi
    "$1_$(basename "$2")" "$3"
    exit
fi

if [ x"$TRAVIS_OS_NAME" = x ]; then
    true
else
    if [ x"$BUILD_OS_NAME" = x ]; then
        BUILD_OS_NAME=$TRAVIS_OS_NAME
    fi
fi

if [ x"$BUILD_OS_NAME" = x'linux' ]; then
    if [ -e "$MYTMPDIR" ]; then
        rm -r "$MYTMPDIR"
    fi
    if [ x"$CODECOV" = x'yes' ]; then
        init_codecov
    fi
    if [ x"$DOCKER_BUILD_DEBUG" = x'yes' ]; then
        mkdir -p  "$MYTMPDIR"
        touch "$MYDOCKERBUILDDEBUGFILENAME"
    fi
    if [ x"$DISTRO" = x'centos' -o x"$DISTRO $VER" = x'ubuntu 14.04' ]; then
        mkdir -p  "$MYTMPDIR"
        curl --retry 3 -S -o "$MYMVNTAR" "$MYMVN_URL"
        if [ x"$DISTRO $VER" = x'centos 5' ]; then
            # Download here as curl/openssl and root certs are dated on centos5,
            # and https downloads don't work.
            curl --retry 3 -S -o "$MYCENTOSEPEL_RPM" \
                'https://archive.fedoraproject.org/pub/archive/epel/5/x86_64/epel-release-5-4.noarch.rpm'
        fi
    fi
    MYSRCD="$(pwd)"
    ulimit -c unlimited
    if [ x"$BUILD_RUN_DOCKER" = x'no' ]; then
        "$0" build "$DISTRO" "$VER" "$BTYPE" "$BUSER"
    else
        if [ x"${DOCKER_IMAGE_PREFIX+x}" = x ]; then
            if [ x"$DISTRO" = x'centos' -a 7 -lt $VER ]; then
                DOCKER_IMAGE_PREFIX='tgagor/'
            else
                DOCKER_IMAGE_PREFIX=''
            fi
        fi
        docker run --rm --dns=8.8.8.8 -t -v "$MYSRCD:$MYSRCD" -w "$MYSRCD" \
            "$DOCKER_IMAGE_PREFIX$DISTRO:$VER" \
            /bin/bash ./travis/script.sh build "$DISTRO" "$VER" "$BTYPE" "$BUSER"
    fi
elif [ x"$BUILD_OS_NAME" = x'osx' ]; then
    set_build_type "$BTYPE"
    for pkg_name in \
            'openssl@1.1' \
            'openssl' \
            ; do
        MYSSLD=$(brew list "$pkg_name" | sed -ne 's/^\(.*\)\/bin\/.*$/\1/p' \
            | sort -u | head -1)
        [ -d "$MYSSLD" ] && break
    done
    if [ -d "$MYSSLD" ]; then
        MYCMAKE_OPTIONS="$MYCMAKE_OPTIONS -D OPENSSL_ROOT_DIR=${MYSSLD}"
        MYSSLBIND="$MYSSLD/bin"
        if [ -f "$MYSSLBIND/openssl" ] && \
                PATH="$MYSSLBIND:$PATH" \
                openssl version > /dev/null 2>&1; then
            PATH="$MYSSLBIND:$PATH"
            export PATH
        fi
    fi
    make rat clean
    sysctl machdep.cpu || true
    df -h || true
    do_build -j 2
else
    echo "OS: $BUILD_OS_NAME not yet supported"
    exit 1
fi
