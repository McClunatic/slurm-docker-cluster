# Multi-stage Dockerfile for Slurm runtime
# Stage 1: Build gosu from source with latest Go (avoids CVEs in pre-built binaries)
# Stage 2: Build RPMs using the builder image
# Stage 3: Install RPMs in a clean runtime image

ARG SLURM_VERSION
ARG GOSU_VERSION=1.19
ARG SPACK_TAG=v1.1.1
# BUILDER_BASE and RUNTIME_BASE overridden when GPU_ENABLE=true is set in .env
ARG BUILDER_BASE=rockylinux/rockylinux:9
ARG RUNTIME_BASE=rockylinux/rockylinux:9

# ============================================================================
# Stage 1: Build gosu from source
# (pre-built binaries use an old Go version that triggers CVEs)
# https://github.com/tianon/gosu/issues/136
# ============================================================================
FROM golang:1.26-bookworm AS gosu-builder

ARG GOSU_VERSION
ARG TARGETOS
ARG TARGETARCH

RUN set -ex \
    && git clone --branch ${GOSU_VERSION} --depth 1 \
       https://github.com/tianon/gosu.git /go/src/github.com/tianon/gosu \
    && cd /go/src/github.com/tianon/gosu \
    && go mod download \
    && CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
       go build -v -trimpath -ldflags '-d -w' \
       -o /go/bin/gosu . \
    && chmod +x /go/bin/gosu

# ============================================================================
# Stage 2: Build RPMs
# ============================================================================
FROM ${BUILDER_BASE} AS builder

ARG SPACK_TAG
ARG SLURM_VERSION

# Install RPM build tools and dependencies for Spack
RUN set -ex && \
    dnf -y install \
    file \
    bzip2 \
    ca-certificates \
    git \
    gzip \
    patch \
    python3 \
    tar \
    unzip \
    xz \
    zstd \
    gcc-toolset-15-gcc \
    gcc-toolset-15-gcc-c++ \
    gcc-toolset-15-gcc-gfortran

# Prepend the gcc-toolset-15 bin directory so Spack and all build processes
# pick up the toolset compilers (gcc, g++, gfortran) before any system GCC.
ENV PATH=/opt/rh/gcc-toolset-15/root/usr/bin:${PATH}

RUN git clone --depth=2 --branch "${SPACK_TAG}" \
    https://github.com/spack/spack.git /opt/spack.git

RUN . /opt/spack.git/share/spack/setup-env.sh && \
    spack env create slurm && \
    spack env activate slurm && \
    spack add flux-sched && \
    spack add munge localstatedir=/var && \
    spack add python && \
    spack add py-pip && \
    spack add slurm@$(echo ${SLURM_VERSION} | tr . -) +cgroup +mariadb +pmix +restd sysconfdir=/etc/slurm && \
    sed -i /view/d /opt/spack.git/var/spack/environments/slurm/spack.yaml && \
    spack config add "view:default:root:/opt/spack" && \
    spack config add "view:default:link_type:hardlink" && \
    spack config add "mirrors:mirror:url:/mirror" && \
    spack config add "mirrors:mirror:signed:false"

# This layer takes a long time. It is placed after the cheap layers so that
# changes to entrypoints, config files, or the runtime stage do not
# invalidate this cache.
RUN --mount=type=cache,target=/mirror \
    . /opt/spack.git/share/spack/setup-env.sh && \
    spack env activate slurm && \
    spack concretize && \
    spack install --fail-fast && \
    spack buildcache push mirror && \
    spack gc -y

# Install Python packages into the Spack-managed Python inside the view
RUN . /opt/spack.git/share/spack/setup-env.sh && \
    spack env activate slurm && \
    pip install \
    flux-python==$(spack find --format "{version}" flux-core) \
    'parsl[visualization,monitoring,flux]'

# ============================================================================
# Stage 3: Runtime image
# ============================================================================
FROM ${RUNTIME_BASE}

LABEL org.opencontainers.image.source="https://github.com/McClunatic/slurm-docker-cluster" \
      org.opencontainers.image.title="slurm-docker-cluster" \
      org.opencontainers.image.description="Slurm Docker cluster on UBI 8" \
      maintainer="Brian McClune"

ARG SLURM_VERSION
ARG TARGETARCH
ARG GPU_ENABLE

# Install minimal OS runtime packages not provided by the Spack view:
#
#   ca-certificates  — TLS root certs for outbound HTTPS from jobs
#   sudo             — interactive users need sudo for dev convenience
#   hostname         — provides `hostname` for worker nodes
#   procps-ng        — provides `pidof` for health checks
#   openssh-server   — allows `ssh` into containers for interactive testing
#   openssh-clients  — allows `ssh` out of containers (e.g. file staging tests)
#
# Intentionally NOT installed here:
#   munge, mariadb, slurm — all provided by /opt/spack copied below
RUN dnf install -y \
        ca-certificates \
        sudo \
        hostname \
        procps-ng \
        openssh-server \
        openssh-clients && \
    ssh-keygen -A && \
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config  && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    dnf clean all

# Install gosu (built from source in stage 1)
COPY --from=gosu-builder /go/bin/gosu /usr/local/bin/gosu
RUN gosu --version && gosu nobody true

# Copy the view and the package store from the builder stage.
#
# /opt/spack               — unified bin/lib/include tree; used for env
# /opt/spack.git/opt/spack — the Spack install tree; required because binaries
#                            reference their install prefix at runtime (rpaths,
#                            compiled-in default paths for logs, pid files, etc.)
COPY --from=builder /opt/spack /opt/spack
COPY --from=builder /opt/spack.git/opt/spack /opt/spack.git/opt/spack

# Set runtime environment so all view binaries and libraries are found
ENV PATH=/opt/spack/bin:/opt/spack/sbin:${PATH}
ENV LD_LIBRARY_PATH=/opt/spack/lib:/opt/spack/lib64
ENV MANPATH=/opt/spack/share/man

# Create users, generate munge key, and set up directories
RUN set -x \
    && groupadd -r --gid=989 munge \
    && useradd -r -g munge --uid=989 \
        --home-dir /run/munge \
        --shell /sbin/nologin \
        munge \
    && groupadd -r --gid=990 slurm \
    && useradd -r -g slurm --uid=990 slurm \
    && groupadd -r --gid=991 slurmrest \
    && useradd -r -g slurmrest --uid=991 slurmrest \
    && chmod 0755 /etc \
    && /opt/spack/sbin/mungekey --create --verbose \
    && find /opt -name munge.key -exec chown munge:munge {} \; \
    && mkdir -m 0755 -p \
        /var/run/munge \
        /var/lib/munge \
        /var/log/munge \
        /var/run/slurm \
        /var/spool/slurm \
        /var/lib/slurm \
        /var/log/slurm \
        /etc/slurm \
    && chown munge:munge \
        /var/run/munge \
        /var/lib/munge \
        /var/log/munge \
    && chown slurm:slurm \
        /var/run/slurm \
        /var/spool/slurm \
        /var/lib/slurm \
        /var/log/slurm \
        /etc/slurm

# Copy Slurm configuration files
# Version-specific configs: Extract major.minor from SLURM_VERSION (e.g., "24.11" from "24.11.6")
COPY config/ /tmp/slurm-config/
RUN set -ex \
    && MAJOR_MINOR=$(echo ${SLURM_VERSION} | cut -d. -f1,2) \
    && echo "Detected Slurm version: ${MAJOR_MINOR}" \
    && if [ -f "/tmp/slurm-config/${MAJOR_MINOR}/slurm.conf" ]; then \
         echo "Using version-specific config for ${MAJOR_MINOR}"; \
         cp /tmp/slurm-config/${MAJOR_MINOR}/slurm.conf /etc/slurm/slurm.conf; \
       else \
         echo "No version-specific config found for ${MAJOR_MINOR}, using latest (25.11)"; \
         cp /tmp/slurm-config/25.11/slurm.conf /etc/slurm/slurm.conf; \
       fi \
    && cp /tmp/slurm-config/common/slurmdbd.conf /etc/slurm/slurmdbd.conf \
    && if [ -f "/tmp/slurm-config/${MAJOR_MINOR}/cgroup.conf" ]; then \
         echo "Using version-specific cgroup.conf for ${MAJOR_MINOR}"; \
         cp /tmp/slurm-config/${MAJOR_MINOR}/cgroup.conf /etc/slurm/cgroup.conf; \
       else \
         echo "Using common cgroup.conf"; \
         cp /tmp/slurm-config/common/cgroup.conf /etc/slurm/cgroup.conf; \
       fi \
    && if [ "$GPU_ENABLE" = "true" ]; then \
         echo "GPU support enabled, installing gres.conf"; \
         cp /tmp/slurm-config/common/gres.conf /etc/slurm/gres.conf; \
         chown slurm:slurm /etc/slurm/gres.conf; \
         chmod 644 /etc/slurm/gres.conf; \
       else \
         echo "GPU support disabled, skipping gres.conf"; \
       fi \
    && chown slurm:slurm /etc/slurm/slurm.conf /etc/slurm/cgroup.conf /etc/slurm/slurmdbd.conf \
    && chmod 644 /etc/slurm/slurm.conf /etc/slurm/cgroup.conf \
    && chmod 600 /etc/slurm/slurmdbd.conf \
    && rm -rf /tmp/slurm-config
COPY --chown=slurm:slurm --chmod=0600 examples /root/examples

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

CMD ["slurmdbd"]
