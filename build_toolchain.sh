#!/bin/bash

OUR_CONTEXT=""

function cleanup {
    if [ ! -z $OUR_CONTEXT ];
    then
        printf "Removing: $OUR_CONTEXT\n"
        rm -f $HERE/deps/$OUR_CONTEXT
    fi
}
trap cleanup EXIT

# Check that all the required programs are installed
function check_programs {
  programs="cargo curl dpkg-deb git make"

  for i in $programs; do
    which $i 1>/dev/null 2>/dev/null

    if [ $? -ne 0 ]; then
        printf "error: $i not found, install it before running this script\n"
        exit 1;
    fi
  done
}

check_programs

# Builds a full cross compiling toolchain for Rust armv7 targets like the
# Raspberry Pi 2, with support for programs using openssl.

if [ $# -ne 1 ];
then
  echo "Usage: $0 dest_dir"
  exit
fi

# Make crosstool-NG happy
unset LD_LIBRARY_PATH

# Downloads a deb file if we don't have a local version already.
function get_deb {
  if [ ! -f $HERE/deps/$2.deb ];
  then
    curl http://archive.raspbian.org/raspbian/pool/main/$1/$2.deb -o $HERE/deps/$2.deb
  fi

  dpkg-deb -x $HERE/deps/$2.deb $HERE/deps/deb
}

# Update a repository if needed. Returns whether an update occured.
# call with : update_repo name url revision
function update_repo {
  NAME=$1
  URL=$2
  if [ -d ./deps/$NAME ];
  then
    (cd ./deps/$NAME && git pull --recurse-submodules=yes)
  else
    git clone --recursive $URL deps/$NAME
  fi
  pushd $HERE/deps/$NAME
  git checkout $3 .
  popd

  if [ -f ./deps/$NAME-commit ];
  then
    CURRENT_COMMIT=$(cat ./deps/$NAME-commit)
  else
    CURRENT_COMMIT="_"
  fi

  NEW_COMMIT=`git --git-dir=./deps/$NAME/.git log -1 --format=%H HEAD`
  echo $NEW_COMMIT > ./deps/$NAME-commit

  OUR_CONTEXT="$NAME-commit"

  if [ "$CURRENT_COMMIT" != "$NEW_COMMIT" ];
  then
    return 1
  else
    return 0
  fi
}

export DEST_DIR=$1
HERE=`pwd`

mkdir -p deps/deb
mkdir -p $DEST_DIR

export PATH=$DEST_DIR/bin:$DEST_DIR/x-tools/bin:$PATH

TARGET=armv7-unknown-linux-gnueabihf

# Clone and build crosstool-ng

update_repo crosstool-ng https://github.com/crosstool-ng/crosstool-ng.git HEAD

if [ $? -eq 1 ];
then
  (cd deps/crosstool-ng/ && ./bootstrap && ./configure --prefix=$DEST_DIR && make -j `nproc` && make install) || exit 1

  ct-ng build || exit 1
  cat build.log
  rm build.log
fi

OUR_CONTEXT=""

# Clone and build Rust

update_repo rust https://github.com/rust-lang/rust.git HEAD #fae516277b6da46b6c1cf568765c90fad2f9ae4b #f5f8e0bfbeee2abc425f26a3ad36430f23010e69 

if [ $? -eq 1 ];
then
  (cd deps/rust && ./configure --prefix=$DEST_DIR --target=$TARGET && make -j `nproc` && make install) || exit 1
fi

OUR_CONTEXT=""

# Clone and build cargo

# Update PATH to get rustc
export PATH=$DEST_DIR/bin:$DEST_DIR/x-tools/bin:$PATH

update_repo cargo https://github.com/rust-lang/cargo.git

if [ $? -eq 1 ];
then
  (cd deps/cargo && ./configure --prefix=$DEST_DIR && make -j `nproc` && make install) || exit 1
fi

OUR_CONTEXT=""

# Download additional deb packages and patch the toolchain's sysroot.

get_deb o/openssl libssl-dev_1.0.1k-3+deb8u2_armhf
get_deb o/openssl libssl1.0.0_1.0.1k-3+deb8u2_armhf
get_deb s/sqlite3 libsqlite3-dev_3.8.7.1-1+deb8u1_armhf
get_deb z/zlib zlib1g_1.2.8.dfsg-2+b1_armhf
get_deb z/zlib zlib1g-dev_1.2.8.dfsg-2+b1_armhf

SYSROOT=$DEST_DIR/x-tools/arm-unknown-linux-gnueabihf/sysroot
chmod u+w $SYSROOT
chmod u+w $SYSROOT/lib
chmod u+w $SYSROOT/usr
chmod u+w $SYSROOT/usr/include
chmod u+w $SYSROOT/usr/share
chmod u+w $SYSROOT/usr/lib

cp -R ./deps/deb/lib $SYSROOT/
cp -R ./deps/deb/usr $SYSROOT/

chmod u-w $SYSROOT/usr/lib
chmod u-w $SYSROOT/usr/share
chmod u-w $SYSROOT/usr/include
chmod u-w $SYSROOT/usr
chmod u-w $SYSROOT/lib
chmod u-w $SYSROOT

# Adding the custom linker

cat > $DEST_DIR/bin/rustpi-linker <<EOF
#!/bin/bash
arm-linux-gnueabihf-gcc --sysroot=$SYSROOT -L $SYSROOT/usr/lib/arm-linux-gnueabihf "\$@"
EOF

chmod u+x $DEST_DIR/bin/rustpi-linker

# If the user has no .cargo/config file, create one. If not, prompt before adding.
# Should be replaced by something a bit more clever that actually parses the
# config file if it exists.

function create_cargo_config() {
  mkdir -p $HOME/.cargo
  cat > $HOME/.cargo/config <<EOF
[target.$TARGET]
linker = "rustpi-linker"
EOF
}

if [ ! -f $HOME/.cargo/config ];
then
  create_cargo_config
else
  LINKER=$(grep rustpi-linker $HOME/.cargo/config)
  if [ "$LINKER" == "" ];
  then
    echo "No linker found in your .cargo/config!"
  else
    echo "Current linker found: $LINKER"
  fi

  echo "Do you wish to update your cargo config file with target specific setup?"
  select yn in "Yes" "No"; do
      case $yn in
          Yes ) create_cargo_config; break;;
          No ) break;;
      esac
  done
fi

cp cargopi $DEST_DIR/bin

# Help people setup their environment. This creates a script to source before
# compiling.

cat > rustpi-env.sh <<EOF
#!/bin/bash
export PATH=$DEST_DIR/bin:$DEST_DIR/x-tools/bin:\$PATH
export LD_LIBRARY_PATH=$DEST_DIR/lib:\$LD_LIBRARY_PATH
export OPENSSL_LIB_DIR=$SYSROOT/usr/lib/arm-linux-gnueabihf/
export TARGET_CFLAGS="-I $SYSROOT/usr/include/arm-linux-gnueabihf"
EOF

echo "=================================================================="
echo " Run source ./rustpi-env.sh to setup your compilation environment."
echo "=================================================================="

# Check that we can compile and link a simple test program.

export LD_LIBRARY_PATH=$DEST_DIR/lib:$LD_LIBRARY_PATH
export OPENSSL_LIB_DIR=$SYSROOT/usr/lib/arm-linux-gnueabihf/
export TARGET_CFLAGS="-I $SYSROOT/usr/include/arm-linux-gnueabihf"

pushd test
cargo build --release --target=$TARGET

if [ $? -eq 0 ];
then
  echo "=================================================================="
  echo " Hooray! your toolchain works!"
  echo "=================================================================="
fi

popd

tar czf toolchain.tar.gz $DEST_DIR
