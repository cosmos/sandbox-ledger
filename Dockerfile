# Based on https://github.com/cosmos/gaia/blob/7c59858e697ad96ab432407ebc944edccec6281c/Dockerfile
FROM golang:1.25-alpine AS builder

RUN apk add --no-cache curl build-base git bash file linux-headers eudev-dev

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN make build

FROM alpine:3.21

# Create a non-root system user.
RUN addgroup -S -g 1000 sandbox \
    && adduser  -S -G sandbox -u 1000 -h /home/sandbox sandbox

# /data holds chain state (genesis, keyring, db, logs). Writable by the
# sandbox user; meant to be backed by a mounted volume in production.
RUN mkdir -p /data \
    && chown sandbox:sandbox /data \
    && chmod 0700 /data

# Install the binary as root-owned, world-executable, no write bits.
# Non-root runtime user cannot modify, replace, or remove it (parent /bin is root-owned 0755).
COPY --from=builder --chown=root:root --chmod=0555 /src/build/sandboxd /bin/sandboxd

USER sandbox:sandbox
WORKDIR /data
VOLUME ["/data"]

ENTRYPOINT ["sandboxd"]
CMD ["start", "--home=/data"]