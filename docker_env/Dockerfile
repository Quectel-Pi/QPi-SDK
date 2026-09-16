FROM ubuntu:22.04

# Add tools
ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update
RUN apt install -y software-properties-common
RUN add-apt-repository -y ppa:deadsnakes/ppa
RUN apt-get update
RUN apt-get install -y git-core gnupg flex bison build-essential zip curl zlib1g-dev \
						libc6-dev-i386 libncurses5 lib32ncurses5-dev x11proto-core-dev \
						libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc \
						unzip fontconfig pv chrpath cpio diffstat gawk wget zstd  liblz4-tool \
						rsync libxml-simple-perl libelf-dev uuid-dev python3.9 python3.8  python2.7 \
						xmlstarlet texinfo  libarchive-dev ssh libselinux1-dev \
						fakechroot libiberty-dev qemu-user-static g++ gcc \
						make libwayland-dev fakeroot libpam0g-dev openjdk-8-jdk-headless binutils-dev \
						util-linux uuid-dev  python3-distutils \
						bc device-tree-compiler python3-pefile sudo btrfs-progs \
						mtools cmake usbutils libusb-1.0-0 libxml2-dev libzip-dev \
						p7zip-full libssl-dev

# Set the locale
RUN apt-get install -y locales
RUN locale-gen en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8


RUN ln -sf /usr/bin/python2.7 /usr/bin/python
RUN ln -sf /usr/bin/python3.9 /usr/bin/python3

RUN echo 'root:root' | chpasswd
RUN useradd -m q1000
RUN useradd -m q1001
RUN useradd -m q1002
RUN useradd -m q1003
RUN useradd -m q1004
RUN useradd -m q1005
RUN useradd -m q1006
RUN useradd -m q1007
RUN useradd -m q1008
RUN useradd -m q1009
RUN useradd -m q1010
RUN useradd -m q1011
RUN useradd -m q1012
RUN useradd -m q1013
RUN useradd -m q1014
RUN useradd -m q1015
RUN useradd -m q1016
RUN useradd -m q1017
RUN useradd -m q1018
RUN useradd -m q1019
RUN useradd -m q1020
RUN echo "q1000 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1001 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1002 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1003 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1004 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1005 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1006 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1007 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1008 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1009 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1010 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1011 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1012 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1013 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1014 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1015 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1016 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1017 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1018 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1019 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
RUN echo "q1020 ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers
ENV SHELL /bin/bash

RUN rm /bin/sh && ln -sf /bin/bash /bin/sh

#RUN ln -sf /bin/bash /bin/sh
#RUN rm -rf /var/lib/apt/lists/*
