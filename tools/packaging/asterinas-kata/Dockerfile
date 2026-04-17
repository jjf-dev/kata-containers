ARG ASTERINAS_BASE_IMAGE=asterinas/asterinas:0.17.2-20260407
FROM ${ASTERINAS_BASE_IMAGE}

ARG KATA_STATIC_TARBALL_RELEASE_REPO=kata-containers/kata-containers
ARG KATA_STATIC_TARBALL_URL=
ARG ASTERINAS_RELEASE_VERSION=
ARG ASTERINAS_DOCKER_IMAGE_VERSION=

WORKDIR /root/asterinas

COPY tools/kata /root/asterinas/tools/kata

RUN KATA_STATIC_TARBALL_RELEASE_REPO="${KATA_STATIC_TARBALL_RELEASE_REPO}" \
    KATA_STATIC_TARBALL_URL="${KATA_STATIC_TARBALL_URL}" \
    bash /root/asterinas/tools/kata/kata_env.sh install

RUN printf '%s\n' "${ASTERINAS_RELEASE_VERSION}" > /root/asterinas/.asterinas-version && \
    printf '%s\n' "${ASTERINAS_DOCKER_IMAGE_VERSION}" > /root/asterinas/.asterinas-docker-image-version
