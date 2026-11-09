FROM dart:3.13.5 AS verify
WORKDIR /workspace
COPY packages/info_core packages/info_core
COPY packages/info_storage packages/info_storage
COPY packages/info_workspace packages/info_workspace
COPY apps/server apps/server
COPY packages/info_remote packages/info_remote
COPY packages/info_cli packages/info_cli
WORKDIR /workspace/packages/info_cli
RUN dart pub get --enforce-lockfile
WORKDIR /workspace/apps/server
RUN dart pub get --enforce-lockfile
CMD ["dart", "test", "--reporter", "expanded"]

FROM verify AS build
RUN dart build cli --target bin/server.dart --output /out

# AOT and its native SQLCipher asset; no SDK, source, data or private keys.
FROM debian:trixie-slim AS runtime
ARG SOURCE_COMMIT=unknown
LABEL org.opencontainers.image.title="Chiyo information server" \
      org.opencontainers.image.revision=$SOURCE_COMMIT
COPY --from=build /out/bundle/ /app/
WORKDIR /app
EXPOSE 47126
STOPSIGNAL SIGTERM
ENTRYPOINT ["/app/bin/server"]
CMD ["serve", "/config/server.json"]
