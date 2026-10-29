# The Linux release build: swift.org's Swift on Ubuntu 26.04, with what
# LinuxArch builds against (see ../README.md) and what `make deb` needs.
# scripts/release-linux.sh builds this image for each architecture.
FROM swift:6.4.1-resolute

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        make dpkg-dev \
        libgtk-4-dev libadwaita-1-dev libsdl3-dev libepoxy-dev \
        libwayland-dev zlib1g-dev libcurl4-openssl-dev \
        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
