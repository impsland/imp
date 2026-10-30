# syntax=docker/dockerfile:1
FROM rust:1.99.1-alpine3.24 AS build
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY crates crates
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked --bin den --bin hop \
    && install -D target/release/den /out/den \
    && install -D target/release/hop /out/hop

FROM alpine:3.24.3
RUN adduser -D -H -u 10001 imp && install -d -o imp -g imp /data
COPY --from=build /out/den /out/hop /usr/local/bin/
USER imp
WORKDIR /data
ENV DEN_DATABASE=/data/den.db
EXPOSE 8080 4677
ENTRYPOINT ["/usr/local/bin/den"]
