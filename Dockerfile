# Stage 1: Build the Haskell project
FROM haskell:9.6-bullseye AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y curl gnupg lsb-release libpq-dev zlib1g zlib1g-dev && \
    mkdir -p /etc/apt/keyrings && \
    curl -o /etc/apt/keyrings/postgresql.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc && \
    echo "deb [signed-by=/etc/apt/keyrings/postgresql.asc] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y postgresql-14

WORKDIR /usr/src/app

COPY tesladb.cabal ./
RUN cabal update && cabal build --only-dependencies

COPY . ./
RUN cabal install

# Stage 2: Create the final image
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y libpq5 zlib1g ca-certificates

WORKDIR /usr/local/bin

# Copy the built executable from the builder stage
COPY --from=builder /root/.local/bin/tesladb /root/.local/bin/teslauth /root/.local/bin/teslacatcher .

VOLUME /data
WORKDIR /data

ENTRYPOINT ["/usr/local/bin/tesladb"]
