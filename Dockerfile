# Based on https://github.com/cosmos/gaia/blob/7c59858e697ad96ab432407ebc944edccec6281c/Dockerfile
# BUILDTYPE=source (default): compile from source; BUILDTYPE=prebuilt: inject pre-built binary via CI.
ARG BUILDTYPE=source

FROM golang:1.25-alpine AS build-source
RUN apk add --no-cache curl build-base git bash file linux-headers eudev-dev
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN make build && cp /src/build/sandboxd /sandboxd

FROM scratch AS build-prebuilt
ARG TARGETARCH=amd64
COPY build/sandboxd-linux-${TARGETARCH} /sandboxd

FROM build-${BUILDTYPE} AS binary

FROM alpine:3.21

RUN addgroup -S -g 1000 sandbox \
    && adduser  -S -G sandbox -u 1000 -h /home/sandbox sandbox

RUN mkdir -p /data \
    && chown sandbox:sandbox /data \
    && chmod 0700 /data

COPY --from=binary --chown=root:root --chmod=0555 /sandboxd /bin/sandboxd

USER sandbox:sandbox
WORKDIR /data
VOLUME ["/data"]

ENTRYPOINT ["sandboxd"]
CMD ["start", "--home=/data"]