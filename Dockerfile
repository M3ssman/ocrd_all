# ocrd/all: fat container integrating (most) OCR-D modules
# pros:
# - single-point of update for docker installation
#   (just as ocrd_all is single-point of update for
#    repo/executable names and dependencies/idiosyncrasies)
# - flexibility in using unpublished changes from modules
#   in a consistent state (just as ocrd_all for local installation)
# - no need to prepare/synchronize module containers for
#   docker-compose / kubernetes
# cons:
# - needs submodules checked out at build time,
#   which implies a huge build context
# - needs to pull in all possible dependencies,
#   which implies a huge final image
# - danger of running into inconsistent dependencies
#   between modules (just as ocrd_all for local installation)

# use OCR-D base container
ARG BASE_IMAGE=ocrd/core
FROM $BASE_IMAGE
ARG BASE_IMAGE
ARG VCS_REF
ARG BUILD_DATE
LABEL \
    maintainer="https://ocr-d.de/en/contact" \
    org.label-schema.vcs-ref=$VCS_REF \
    org.label-schema.vcs-url="https://github.com/OCR-D/ocrd_all" \
    org.label-schema.build-date=$BUILD_DATE


# simulate a virtual env for the makefile,
# coinciding with the Python system prefix
ENV PREFIX=/usr/local
ENV VIRTUAL_ENV $PREFIX
# avoid HOME/.local/share (hard to predict USER here)
# so let XDG_DATA_HOME coincide with fixed system location
# (can still be overridden by derived stages)
ENV XDG_DATA_HOME /usr/local/share
# avoid the need for an extra volume for persistent resource user db
# (i.e. XDG_CONFIG_HOME/ocrd/resources.yml)
ENV XDG_CONFIG_HOME /usr/local/share/ocrd-resources
# declaring volumes prevents derived stages
# from placing data there (cannot be undeclared),
# preventing the use-case of images bundled with models;
# also, this adds little value over runtime --mount
# VOLUME $XDG_DATA_HOME/ocrd-resources
# see below (after make all) for an ex-post symlink to /models
ENV HOME /

# enable caching in OcrdMets for better performance
ENV OCRD_METS_CACHING=1

# make apt run non-interactive during build
ENV DEBIAN_FRONTEND noninteractive

ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8
ENV TF_FORCE_GPU_ALLOW_GROWTH=true

# allow passing build-time parameter for list of tools to be installed
# (defaults to medium, which also requires those modules to be present)
ARG OCRD_MODULES="core cor-asv-ann dinglehopper docstruct format-converters nmalign ocrd_calamari ocrd_cis ocrd_fileformat ocrd_im6convert ocrd_keraslm ocrd_olahd_client ocrd_olena ocrd_pagetopdf ocrd_repair_inconsistencies ocrd_segment ocrd_tesserocr ocrd_wrap workflow-configuration"
# persist that variable for build-time make to pick it up and run-time users to know what to expect
ENV OCRD_MODULES="${OCRD_MODULES}"

# allow passing build-time parameter for pip install options
# (defaults to no extra options)
ARG PIP_OPTIONS=""

# allow passing build-time parameter for Python version
# (defaults to python3 in all modules)
ARG PYTHON=python3

# build in parallel to speed up (but risk running into clashes
# when not all dependencies have been correctly explicated):
ARG PARALLEL=""

# increase default network timeouts (so builds don't fail because of small bandwidth)
ENV PIP_OPTIONS="--timeout=3000 ${PIP_OPTIONS}"
RUN echo "Acquire::http::Timeout \"3000\";" >> /etc/apt/apt.conf.d/99network && \
    echo "Acquire::https::Timeout \"3000\";" >> /etc/apt/apt.conf.d/99network && \
    echo "Acquire::ftp::Timeout \"3000\";" >> /etc/apt/apt.conf.d/99network

WORKDIR /build

# from-stage already contains a clone clashing with build context
RUN rm -rf /build/core/.git

# copy (sub)module directories to build
# (ADD/COPY cannot copy a list of directories,
#  so we must rely on .dockerignore here)
COPY . .

# TODO(kba)
# verify we got the right version of core
# RUN bash -c 'CORE_VERSION=`git -C /build/core describe --tags`; if [[ "$BASE_IMAGE" != *":$CORE_VERSION" ]]; then echo $BASE_IMAGE inconsistent with core version $CORE_VERSION; exit 1;fi'

# make apt system functional
RUN apt-get -y update && apt-get install -y apt-utils

# avoid git submodule update (keep at build context)
ENV NO_UPDATE=1

# run build in one layer/step (to minimise image size)
RUN set -ex && \
# get packages for build
    apt-get -y install automake autoconf libtool pkg-config g++ && \
# ensure no additional git actions happen after copying the checked out modules
# try to fetch all modules system requirements
    make deps-ubuntu && \
    . $VIRTUAL_ENV/bin/activate && \
    pip install -U pip setuptools wheel && \
# build/install all tools of the requested modules:
    make $PARALLEL all && \
# remove unneeded automatic deps and clear pkg cache
    apt-get -y remove automake autoconf libtool pkg-config g++ && \
    apt-get -y clean && \
# clean-up some temporary files (git repos are also installation targets and must be kept)
    make -i clean-tesseract && \
    make -i clean-olena && \
    rm -fr /.cache && \
# update ld.so cache for new libs in /usr/local
    ldconfig
# check installation
RUN make -j4 check CHECK_HELP=1
RUN if echo $BASE_IMAGE | fgrep -q cuda; then make fix-cuda; fi

# as discussed in #378, we do not want to manage more than one resource location
# to mount for model persistence; with named volumes, the preinstalled models
# will be copied to the host and complemented by downloaded models; tessdata
# is the only problematic module location
RUN mkdir -p  $XDG_DATA_HOME/tessdata; \
# as seen in #394, this must never be repeated
    if ! test -d $XDG_CONFIG_HOME/ocrd-tesserocr-recognize; then \
    mv -v $XDG_DATA_HOME/tessdata $XDG_CONFIG_HOME/ocrd-tesserocr-recognize && \
    ln -vs $XDG_CONFIG_HOME/ocrd-tesserocr-recognize $XDG_DATA_HOME/tessdata; fi

# finally, alias/symlink all ocrd-resources to /models for shorter mount commands
RUN mkdir -p $XDG_CONFIG_HOME; \
# as seen in #394, this must never be repeated
    if ! test -d /models; then \
    mv -v $XDG_CONFIG_HOME /models && \
    ln -vs /models $XDG_CONFIG_HOME; fi; \
# ensure unprivileged users can download models, too
    chmod go+rwx /models

# smoke-test resmgr
RUN ocrd resmgr list-installed && \
    # clean possibly created log-files/dirs of ocrd_network logger to prevent permission problems
    rm -rf /tmp/ocrd_*

# remove (dated) security workaround preventing use of
# ImageMagick's convert on PDF/PS/EPS/XPS:
RUN sed -i 's/rights="none"/rights="read|write"/g' /etc/ImageMagick-6/policy.xml; \
# prevent cache resources exhausted errors
    sed -i 's/name="disk" value="1GiB"/name="disk" value="8GiB"/g' /etc/ImageMagick-6/policy.xml; \
# relax overly restrictive maximum resolution
    sed -i '/width\|height/s/value="16KP"/value="64KP"/' /etc/ImageMagick-6/policy.xml; true

# avoid default prompt with user name, because likely we will use host UID without host /etc/passwd
# cannot just set ENV, because internal bashrc will override it anyway
RUN echo "PS1='\w\$ '" >> /etc/bash.bashrc

# reset to interactive
ENV DEBIAN_FRONTEND teletype

WORKDIR /data
# make writable for any user that logs in
RUN chmod 777 /data
# will usually be mounted over
VOLUME /data

# no fixed entrypoint
CMD /bin/bash

# further data files (like OCR models) could be installed
# in a multi-staged build using FROM ocrd/all...
