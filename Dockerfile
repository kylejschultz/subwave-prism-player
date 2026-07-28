# syntax=docker/dockerfile:1

# Builds a standalone SUB/WAVE web image from a pinned git ref.
# The deploy repo owns the container/deploy shape; the player implementation
# stays in the real SUB/WAVE source tree.

ARG NODE_IMAGE=node:22-bookworm-slim

FROM ${NODE_IMAGE} AS source
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

ARG SUBWAVE_REPO=https://github.com/perminder-klair/subwave.git
ARG SUBWAVE_REF=90db93086945eacd07d9a2b5fe607c41a5ec2fe6
ARG SUBWAVE_SKINS_REPO=https://github.com/kylejschultz/subwave-skins.git
ARG SUBWAVE_SKINS_REF=main
ARG APPLY_SUBWAVE_SKINS_PATCHES=1
ARG APPLY_PRISM_DEFAULT_PATCH=1
ARG APPLY_PLAYER_ONLY_PATCH=1

WORKDIR /src
COPY patches/ /patches/
RUN git clone --filter=blob:none "${SUBWAVE_REPO}" subwave \
  && cd subwave \
  && git checkout "${SUBWAVE_REF}" \
  && if [ "${APPLY_SUBWAVE_SKINS_PATCHES}" = "1" ]; then \
       git clone --filter=blob:none "${SUBWAVE_SKINS_REPO}" /src/subwave-skins; \
       cd /src/subwave-skins; \
       git checkout "${SUBWAVE_SKINS_REF}"; \
       cd /src/subwave; \
       for patch in /src/subwave-skins/patches/*.patch; do git apply "${patch}"; done; \
       rm -rf web/components/skins/prism; \
       mkdir -p web/components/skins; \
       cp -R /src/subwave-skins/skins/prism web/components/skins/prism; \
     fi \
  && if [ "${APPLY_PRISM_DEFAULT_PATCH}" = "1" ]; then \
       git apply /patches/prism-default.patch; \
       test -d web/components/skins/prism; \
     fi \
  && if [ "${APPLY_PLAYER_ONLY_PATCH}" = "1" ]; then \
       git apply /patches/player-only.patch; \
     fi

FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY --from=source /src/subwave/web/package.json /src/subwave/web/package-lock.json ./
RUN npm ci

FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=source /src/subwave/web/ ./

ENV NEXT_TELEMETRY_DISABLED=1
ARG SITE_URL
ARG NEXT_PUBLIC_API_URL
ARG NEXT_PUBLIC_STREAM_URL
ARG NEXT_PUBLIC_GA_ID
ARG SUBWAVE_BUILD_VERSION=prism-player
ENV SITE_URL=${SITE_URL}
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}
ENV NEXT_PUBLIC_STREAM_URL=${NEXT_PUBLIC_STREAM_URL}
ENV NEXT_PUBLIC_GA_ID=${NEXT_PUBLIC_GA_ID}
ENV SUBWAVE_BUILD_VERSION=${SUBWAVE_BUILD_VERSION}

RUN npm run build

FROM ${NODE_IMAGE} AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=7700
ENV HOSTNAME=0.0.0.0
ENV SUBWAVE_HOMEPAGE=player

RUN groupadd -r next && useradd -r -g next next

COPY --from=build --chown=next:next /app/.next/standalone ./
COPY --from=build --chown=next:next /app/.next/static ./.next/static
COPY --from=build --chown=next:next /app/public ./public
COPY --from=build --chown=next:next /app/content ./content

USER next
EXPOSE 7700
CMD ["node", "server.js"]
