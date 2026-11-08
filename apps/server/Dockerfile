FROM dart:3.13.5 AS verify
WORKDIR /workspace
COPY packages/info_core packages/info_core
COPY packages/info_storage packages/info_storage
COPY packages/info_workspace packages/info_workspace
COPY apps/server apps/server
COPY packages/info_remote packages/info_remote
COPY packages/info_cli packages/info_cli
WORKDIR /workspace/packages/info_cli
RUN dart pub get
WORKDIR /workspace/apps/server
RUN dart pub get
CMD ["dart", "test", "--reporter", "expanded"]
