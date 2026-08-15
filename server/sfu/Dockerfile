# The call server.
#
# Debian rather than Alpine on purpose: mediasoup's worker is a native
# binary, it publishes prebuilt ones against glibc, and on musl npm falls
# back to building it from source — which works, slowly, and then breaks
# on some future release for reasons nobody wants to debug at the point
# calls stop working.
FROM node:22-bookworm-slim AS build

# Only needed if the prebuilt worker for this platform is unavailable and
# npm falls back to compiling one. Left in the build stage, so none of it
# ends up in the image that runs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential python3 python3-pip pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-bookworm-slim
WORKDIR /app

COPY --from=build /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

# Not root. The worker binds UDP ports in the high range configured
# below, none of which are privileged.
USER node

ENV NODE_ENV=production
ENV PORT=4443

# The signalling socket. The media ports are not listed here on purpose:
# in `--network host`, which is how this should be run, EXPOSE means
# nothing, and under bridge networking a published range of a thousand
# UDP ports takes minutes to start and adds a NAT hop the SFU then has to
# be told to lie about. See README.md.
EXPOSE 4443

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "src/index.js"]
