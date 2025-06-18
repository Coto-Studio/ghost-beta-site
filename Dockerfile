FROM ghost:5-alpine

LABEL org.opencontainers.image.source = "https://github.com/Coto-Studio/ghost-beta-site"

RUN mkdir -p content/adapters/storage \
    && npm install ghost-storage-adapter-s3@2.8.0 \
    && cp -r node_modules/ghost-storage-adapter-s3 content/adapters/storage/s3