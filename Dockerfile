################################################################################
# Copyright 2023, Fraunhofer Institute for Secure Information Technology SIT.  #
# All rights reserved.                                                         #
# ---------------------------------------------------------------------------- #
# Main Dockerfile for CHARRA.                                                  #
# ---------------------------------------------------------------------------- #
# Author:        Michael Eckel <michael.eckel@sit.fraunhofer.de>               #
# Date Modified: 2023-11-30T13:37:42+02:00                                     #
# Date Created:  2019-06-26T09:23:15+02:00                                     #
# ---------------------------------------------------------------------------- #
# Hint: Check your Dockerfile at https://www.fromlatest.io/                    #
################################################################################


## -----------------------------------------------------------------------------
## --- preamble ----------------------------------------------------------------
## -----------------------------------------------------------------------------

## --- global arguments --------------------------------------------------------


## --- set base image(s) -------------------------------------------------------

FROM ghcr.io/tpm2-software/ubuntu-20.04:latest AS base

## --- metadata ----------------------------------------------------------------

LABEL org.opencontainers.image.authors="michael.eckel@sit.fraunhofer.de"

## --- image specific arguments ------------------------------------------------

## user and group
ARG user='bob'
ARG uid=1000
ARG gid=1000

## software versions (typically Git branches or tags)
ARG tpm2tss_version='4.0.1'
ARG tpm2tools_version='5.6'
ARG libcoap_version='v4.3.0'
ARG mbedtls_version='v3.5.1'
ARG qcbor_version='v1.2'
ARG tcose_version='v1.1.1'
ARG pytss_version='2.1.0'


## -----------------------------------------------------------------------------
## --- pre-work for interactive environment ------------------------------------
## -----------------------------------------------------------------------------

## unminimize Ubuntu container image
RUN yes | unminimize

## copy configs
COPY "./docker/dist/etc/default/keyboard" "/etc/default/keyboard"

## system reference manuals (manual pages)
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    man-db \
    manpages-posix \
    manpages-dev \
    && rm -rf /var/lib/apt/lists/*

## Bash command completion
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    bash-completion \
    && rm -rf /var/lib/apt/lists/*


## -----------------------------------------------------------------------------
## --- install dependencies ----------------------------------------------------
## -----------------------------------------------------------------------------

ENV LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/usr/local/lib"

## TPM2 TSS
RUN git clone --depth=1 -b "${tpm2tss_version}" \
    'https://github.com/tpm2-software/tpm2-tss.git' /tmp/tpm2-tss
WORKDIR /tmp/tpm2-tss
RUN git reset --hard \
    && git clean -xdf \
    && ./bootstrap \
    && ./configure --enable-integration --disable-doxygen-doc \
    && make clean \
    && make -j \
    && make install \
    && ldconfig

## make TPM simulator the default for TCTI
RUN ln -sf 'libtss2-tcti-mssim.so' '/usr/local/lib/libtss2-tcti-default.so'

## remove TPM2-TSS source files
RUN rm -rf /tmp/tpm2-tss

## TPM2 tools
RUN git clone --depth=1 -b "${tpm2tools_version}" \
    'https://github.com/tpm2-software/tpm2-tools.git' /tmp/tpm2-tools
WORKDIR /tmp/tpm2-tools
RUN ./bootstrap \
    && ./configure \
    && make -j \
    && make install
RUN rm -rfv /tmp/tpm2-tools

## libcoap
RUN git clone --recursive -b "${libcoap_version}" \
    'https://github.com/obgm/libcoap.git' /tmp/libcoap
# Usually the second git checkout should be enough with an added
# '--recurse-submodules', but for some reason this fails in the
# default docker build environment.
# Note: The checkout with submodules works when using Buildkit.
WORKDIR /tmp/libcoap/ext/tinydtls
RUN git checkout 290c48d262b6859443bd4b04926146bda3293c98
WORKDIR /tmp/libcoap
RUN git checkout ea1deffa6b3997eea02635579a4b7fb7af4915e5
COPY "./docker/dist/coap_tinydtls.patch" .
RUN patch -p 1 < coap_tinydtls.patch
RUN ./autogen.sh \
    && ./configure --disable-tests --disable-documentation --disable-manpages --enable-dtls --with-tinydtls --enable-fast-install \
    && make -j \
    && make install
RUN rm -rfv /tmp/libcoap

## mbed TLS
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    python3-jinja2 \
    python3-jsonschema \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --recursive -b "${mbedtls_version}" \
    'https://github.com/ARMmbed/mbedtls.git' /tmp/mbedtls
WORKDIR /tmp/mbedtls
RUN make -j lib SHARED=true \
    && make install
RUN rm -rfv /tmp/mbedtls

## QCBOR
RUN git clone --depth=1 --recursive -b "${qcbor_version}" \
    'https://github.com/laurencelundblade/QCBOR.git' /tmp/qcbor
WORKDIR /tmp/qcbor
RUN make -j all so \
    && make install install_so
RUN rm -rfv /tmp/qcbor

## t_cose
RUN git clone --depth=1 --recursive -b "${tcose_version}" \
    'https://github.com/laurencelundblade/t_cose.git' /tmp/t_cose
WORKDIR /tmp/t_cose
RUN make -j -f Makefile.psa libt_cose.a libt_cose.so \
    &&  make -f Makefile.psa install install_so
RUN rm -rfv /tmp/t_cose


## -----------------------------------------------------------------------------
## --- install tpm2-pytss ------------------------------------------------------
## -----------------------------------------------------------------------------

## upgrade pip
RUN python3 -m pip install --upgrade pip

## install py-tss
RUN python3 -m pip install \
    "git+https://github.com/tpm2-software/tpm2-pytss.git@${pytss_version}"


## -----------------------------------------------------------------------------
## --- further configuration ---------------------------------------------------
## -----------------------------------------------------------------------------

## add 'tss' user and group
## see: <https://github.com/tpm2-software/tpm2-tss/blob/master/Makefile.am#L841>
RUN bash -c ' \
    if test -z "${DESTDIR}"; then \
        if type -p groupadd > /dev/null; then \
            id -g tss 2>/dev/null || groupadd --system tss; \
        else \
            id -g tss 2>/dev/null || \
            addgroup --system tss; \
        fi && \
        if type -p useradd > /dev/null; then \
            id -u tss 2>/dev/null || \
            useradd --system --home-dir / --shell `type -p nologin` \
                             --no-create-home -g tss tss; \
        else \
            id -u tss 2>/dev/null || \
            adduser --system --home / --shell `type -p nologin` \
                    --no-create-home --ingroup tss tss; \
        fi; \
    fi \
    '

## create FAPI system folder(s) for
RUN mkdir -p '/usr/local/var/run/tpm2-tss' \
    && chown 'root:tss' '/usr/local/var/run/tpm2-tss' \
    && chmod g+w '/usr/local/var/run/tpm2-tss'
RUN mkdir -p '/usr/local/var/lib/tpm2-tss' \
    && chown 'root:tss' '/usr/local/var/lib/tpm2-tss' \
    && chmod g+w '/usr/local/var/lib/tpm2-tss'

## install jq tool for JSON manipulation
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    jq \
    && rm -rf /var/lib/apt/lists/*

## configure TSS FAPI to not check EK certificates since we use a TPM simulator
RUN jq --argjson ekCertLess '{"ek_cert_less":"yes"}' '. += $ekCertLess' \
    '/usr/local/etc/tpm2-tss/fapi-config.json' \
    > '/tmp/fapi-config.json' \
    && cat '/tmp/fapi-config.json' \
        > '/usr/local/etc/tpm2-tss/fapi-config.json' \
    && rm -f '/tmp/fapi-config.json'


## -----------------------------------------------------------------------------
## --- install tools -----------------------------------------------------------
## -----------------------------------------------------------------------------

## install debugging tools
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    clang \
    clang-tools \
    cgdb \
    gdb \
    tmux \
    valgrind \
    && rm -rf /var/lib/apt/lists/*


## -----------------------------------------------------------------------------
## --- setup user --------------------------------------------------------------
## -----------------------------------------------------------------------------

## install sudo and gosu
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    gosu \
    sudo \
    && rm -rf /var/lib/apt/lists/*

## create non-root user and grant sudo permission
RUN export user="${user}" uid="${uid}" gid="${gid}" \
    && addgroup --gid "${gid}" "${user}" \
    && adduser --home /home/"${user}" --uid "${uid}" --gid "${gid}" \
    --disabled-password --gecos '' "${user}" \
    && mkdir -vp /etc/sudoers.d/ \
    && echo "${user}     ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/"${user}" \
    && chmod 0440 /etc/sudoers.d/"${user}" \
    && chown "${uid}:${gid}" -R /home/"${user}"


## -----------------------------------------------------------------------------
## --- configuration -----------------------------------------------------------
## -----------------------------------------------------------------------------

## configure Bash
COPY "./docker/dist/home/user/.bashrc" "/home/${user}/.bashrc"
COPY "./docker/dist/home/user/.bash_aliases" "/home/${user}/.bash_aliases"
COPY "./docker/dist/home/user/.bash_history" "/home/${user}/.bash_history"

## disable TSS2 logging
ENV TSS2_LOG=all+none
#ENV TSS2_LOGFILE=none

## set TPM2 tools environment variables
ENV TPM2TOOLS_TCTI_NAME=socket
ENV TPM2TOOLS_SOCKET_ADDRESS=127.0.0.1
ENV TPM2TOOLS_SOCKET_PORT=2321

## install TPM2 helpers (TPM simulator reset script + TSS compile script)
COPY "./docker/dist/usr/local/bin/tpm-reset" "/usr/local/bin/"
COPY "./docker/dist/usr/local/bin/compile-tss" "/usr/local/bin/"

## add tpm2-tss code examples and test script
COPY "./docker/dist/home/user/code-examples/" "/home/${user}/code-examples/"
RUN chown -R "${user}:${user}" "/home/${user}/code-examples/"
COPY "./docker/dist/home/user/test-charra-and-tpm2-tss.sh" "/home/${user}/"

## Docker entrypoint
COPY "./docker/dist/usr/local/bin/docker-entrypoint.sh" "/usr/local/bin/"
## keep backwards compatibility
RUN ln -s '/usr/local/bin/docker-entrypoint.sh' /

## set environment variables
USER "${uid}:${gid}"
ENV HOME /home/"${user}"
WORKDIR /home/"${user}"


## -----------------------------------------------------------------------------
## --- postamble ---------------------------------------------------------------
## -----------------------------------------------------------------------------

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["/bin/bash"]
