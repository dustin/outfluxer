# Stage 1: Build the Haskell project
FROM haskell:9.6-bullseye AS builder

RUN apt-get update && apt-get install -y zlib1g zlib1g-dev

WORKDIR /usr/src/app

COPY outfluxer.cabal ./
RUN cabal update && cabal build --only-dependencies

COPY . ./
RUN cabal install

# Stage 2: Create the final image
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y zlib1g ca-certificates

WORKDIR /usr/local/bin

# Copy the built executable from the builder stage
COPY --from=builder /root/.local/bin/outfluxer .

VOLUME /etc/outfluxer
WORKDIR /etc/outfluxer

COPY test.dhall outfluxer.conf

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

ENTRYPOINT ["/usr/local/bin/outfluxer"]
