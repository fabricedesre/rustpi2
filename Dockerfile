FROM ubuntu:15.04
MAINTAINER Fabrice Desré <fabrice@desre.org>

ADD sources.list /etc/apt/

RUN dpkg --add-architecture armhf
RUN apt-get update
RUN apt-get upgrade -y
RUN apt-get install -y \
  build-essential \
  curl \
  file \
  g++-arm-linux-gnueabihf \
  git

RUN apt-get install -y --no-install-recommends \
  libasound2:armhf \
  libssl-dev:armhf \
  libespeak-dev:armhf \
  libupnp6-dev:armhf \
  libudev-dev:armhf \
  libavahi-client-dev:armhf \
  libsqlite3-dev:armhf

RUN apt-get clean

ENV SHELL=/bin/bash

RUN useradd -m -d /home/user -p user user

# open-zwave wants -cc and -c++ but I could not find a package providing them.
RUN cp /usr/bin/arm-linux-gnueabihf-gcc /usr/bin/arm-linux-gnueabihf-cc
RUN cp /usr/bin/arm-linux-gnueabihf-g++ /usr/bin/arm-linux-gnueabihf-c++

USER user
WORKDIR /home/user

RUN git clone https://github.com/rust-lang/rustup.git

RUN ./rustup/rustup.sh --disable-sudo --prefix=/home/user --channel=nightly --date=2016-04-10 --with-target=armv7-unknown-linux-gnueabihf

ENV PATH=/home/user/bin:$PATH
ENV LD_LIBRARY_PATH=/home/user/lib:$LD_LIBRARY_PATH

# For rust-crypto
ENV CC=arm-linux-gnueabihf-gcc

# For open-zwave
ENV CROSS_COMPILE=arm-linux-gnueabihf-

RUN mkdir -p dev/source
RUN mkdir dev/.cargo

ADD cargopi /home/user/bin
 
ADD rustpi-linker /home/user/bin

WORKDIR /home/user/dev/source

