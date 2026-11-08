FROM dart:3.13.5 AS verify
WORKDIR /workspace
COPY packages/info_core packages/info_core
COPY packages/info_storage packages/info_storage
COPY apps/server apps/server
WORKDIR /workspace/apps/server
RUN dart pub get
CMD ["dart", "test", "--reporter", "expanded"]
