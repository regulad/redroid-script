# Adds Google apps to a pinned redroid base and, on the amd64 Android 15 and 16
# bases, which lack one, the libhoudini ARM translation layer. Every input
# arrives as a build argument that scripts/build.sh reads out of matrix.json,
# where each is pinned: bases and tools by digest, downloads by SHA-256, git
# sources by commit.
#
# Nothing runs on the target architecture. The payload is assembled on the
# build host ($BUILDPLATFORM) and the image itself is the base plus one COPY,
# so either kind of runner builds both architectures, without QEMU.

ARG BASE
ARG TOOLS
ARG GAPPS_KIND
ARG NATIVE_BRIDGE=none

FROM ${BASE} AS base

FROM --platform=${BUILDPLATFORM} ${TOOLS} AS tools
# GNU tar and Info-ZIP unzip, not busybox's: LiteGapps needs tar -J, and only
# Info-ZIP extracts by pattern.
RUN apk add --no-cache curl git tar unzip xz

# --- Google apps ------------------------------------------------------------

FROM tools AS gapps-download
ARG GAPPS_URL
ARG GAPPS_SHA256
RUN curl -fsSL --retry 5 --retry-all-errors -o /gapps.zip "${GAPPS_URL}" \
 && echo "${GAPPS_SHA256}  /gapps.zip" | sha256sum -c -

# A MindTheGapps zip is a recovery package. Its system/ is the tree the
# installer would lay onto the system partition, which redroid keeps at /system
# (with /product and /system_ext inside it); the installer itself is not needed.
FROM gapps-download AS gapps-mindthegapps
RUN mkdir -p /x /out \
 && unzip -q /gapps.zip 'system/*' -d /x \
 && mv /x/system /out/system

# LiteGapps keeps its tree inside files/files.tar.xz, as <abi>/<sdk>/system.
FROM gapps-download AS gapps-litegapps
ARG LITEGAPPS_TREE
RUN mkdir -p /x /out \
 && unzip -q /gapps.zip files/files.tar.xz -d /x \
 && tar -xJf /x/files/files.tar.xz -C /x \
 && mv "/x/${LITEGAPPS_TREE}/system" /out/system

FROM gapps-${GAPPS_KIND} AS gapps

# --- ARM translation --------------------------------------------------------

# arm64 needs none, and redroid's amd64 12, 13 and 14 bases already ship
# libndk_translation behind /system/lib*/libnb.so.
FROM tools AS native-bridge-none
RUN mkdir /out

# Every amd64 base sets ro.dalvik.vm.native.bridge=libnb.so in vendor/build.prop,
# but the 15 and 16 ones have no libnb.so. This supplies libhoudini behind that
# name, its binfmt_misc registrations, and the linker-namespace fix that
# rote66/redroid_libhoudini_hack applies at boot.
FROM tools AS native-bridge-houdini
ARG HOUDINI_REPO
ARG HOUDINI_COMMIT
ARG HACK_REPO
ARG HACK_COMMIT
ARG HACK_ANDROID
# Fetched by commit, not as GitHub's archive zips, whose bytes GitHub does not
# promise to keep the same.
RUN for src in "houdini ${HOUDINI_REPO} ${HOUDINI_COMMIT}" "hack ${HACK_REPO} ${HACK_COMMIT}"; do \
      set -- $src; \
      git init -q "/$1" \
      && git -C "/$1" fetch -q --depth 1 "$2" "$3" \
      && git -C "/$1" checkout -q FETCH_HEAD \
      && test "$(git -C "/$1" rev-parse HEAD)" = "$3" || exit 1; \
    done
COPY --from=base /system/etc/init/hw/init.rc /base-init.rc
COPY native-bridge/ /native-bridge/
# The hack ships a whole init.rc per Android version. Its 15.0.0 one was taken
# from an older redroid 15 build and would undo 182 lines of the pinned base's,
# so the base's own init.rc is used, with only the hack's two lines added.
RUN mkdir -p /out/system/etc/init/hw \
 && cp -a /houdini/prebuilts/. /out/system/ \
 && ln -s libhoudini.so /out/system/lib/libnb.so \
 && ln -s libhoudini.so /out/system/lib64/libnb.so \
 && cp /native-bridge/houdini.rc /out/system/etc/init/houdini.rc \
 && cp "/hack/${HACK_ANDROID}/etc/ld_config.patch" "/hack/${HACK_ANDROID}/etc/ld_config_swcodec.patch" /out/system/etc/ \
 && awk -f /native-bridge/patch-linkerconfig.awk /base-init.rc > /out/system/etc/init/hw/init.rc

FROM native-bridge-${NATIVE_BRIDGE} AS native-bridge

# --- the payload, then the image --------------------------------------------

# Owners and modes are set here rather than inherited from the archives or the
# build host's umask (the 2024 images shipped /system as 0775): everything
# root's, directories 0755, files 0644, and the two interpreters binfmt_misc
# hands ARM programs to, 0755.
FROM tools AS payload
COPY --from=gapps /out/ /p/
COPY --from=native-bridge /out/ /p/
RUN chown -R 0:0 /p \
 && find /p -type d -exec chmod 0755 {} + \
 && find /p -type f -exec chmod 0644 {} + \
 && for f in /p/system/bin/houdini /p/system/bin/houdini64; do \
      if [ -e "$f" ]; then chmod 0755 "$f"; fi; \
    done

FROM base
COPY --link --from=payload /p/ /
# The base's entrypoint, plus a disabled setup wizard: both GApps packages ship
# Google's, and a redroid container has no one at a screen to finish it.
ENTRYPOINT ["/init", "qemu=1", "androidboot.hardware=redroid", "ro.setupwizard.mode=DISABLED"]
