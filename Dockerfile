# Adds Google apps to a pinned redroid base and, on the amd64 Android 15 and 16
# bases, which lack one, the libhoudini ARM translation layer. Every input
# arrives as a build argument that scripts/build.sh reads out of matrix.json,
# where each is pinned: bases and tools by digest, downloads by SHA-256, git
# sources by commit.
#
# The payload is assembled on the build host ($BUILDPLATFORM). The image is the
# base plus that payload, in one COPY, minus AOSP's Provision, which one static
# busybox `rm` takes out. That rm is the only thing that runs on the target
# architecture: for arm64 on an x64 runner, under the QEMU BuildKit ships with.

ARG BASE
ARG TOOLS
ARG BUSYBOX
ARG GAPPS_KIND
ARG NATIVE_BRIDGE=none

FROM ${BASE} AS base

# For the target architecture, as the base is: the busybox:musl build is static.
FROM ${BUSYBOX} AS busybox

FROM --platform=${BUILDPLATFORM} ${TOOLS} AS tools
# GNU tar and Info-ZIP unzip, not busybox's: LiteGapps needs tar -J, and only
# Info-ZIP extracts by pattern.
RUN apk add --no-cache curl git tar unzip xz

# --- Google apps ------------------------------------------------------------

FROM tools AS gapps-download
ARG GAPPS_URL
ARG GAPPS_SHA256
RUN curl -fsSL --retry 8 --retry-all-errors -o /gapps.zip "${GAPPS_URL}" \
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

# An add-on package, laid out as a MindTheGapps zip is, with its system/ tree
# at the top. LiteGapps ships Google's setup wizard as one; see the last stage.
FROM tools AS gapps-addon
ARG ADDON_URL
ARG ADDON_SHA256
RUN mkdir -p /out \
 && if [ -n "${ADDON_URL}" ]; then \
      curl -fsSL --retry 8 --retry-all-errors -o /addon.zip "${ADDON_URL}" \
      && echo "${ADDON_SHA256}  /addon.zip" | sha256sum -c - \
      && unzip -q /addon.zip 'system/*' -d /out; \
    fi

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
#
# Every payload carries exactly one Google setup wizard, which the last stage
# relies on.
FROM tools AS payload
COPY --from=gapps /out/ /p/
COPY --from=gapps-addon /out/ /p/
COPY --from=native-bridge /out/ /p/
RUN wizards=$(find /p/system -path '*/priv-app/SetupWizard*/SetupWizard*.apk' | wc -l) \
 && if [ "$wizards" -ne 1 ]; then \
      echo "expected one Google setup wizard in the payload, found $wizards" >&2; exit 1; \
    fi \
 && chown -R 0:0 /p \
 && find /p -type d -exec chmod 0755 {} + \
 && find /p -type f -exec chmod 0644 {} + \
 && for f in /p/system/bin/houdini /p/system/bin/houdini64; do \
      if [ -e "$f" ]; then chmod 0755 "$f"; fi; \
    done

FROM base
COPY --link --from=payload /p/ /
# Both GApps installers take AOSP's Provision out when they add Google's setup
# wizard. Android grants the setup wizard's own permissions only when exactly
# one app is the setup wizard. With both, Google's is refused them, crashes
# ("WifiService: Permission denied"), and, being the home screen until setup
# is done, keeps crashing. The base has no shell a build can use, so a static
# busybox does it. It is mounted under /dev, which is not part of the image,
# as busybox: it picks the applet from argv[0] unless that names busybox.
# rm without -f fails if the base no longer has Provision there.
RUN --mount=type=bind,from=busybox,source=/bin/busybox,target=/dev/busybox \
    ["/dev/busybox", "rm", "-r", "/system/system_ext/priv-app/Provision"]
# The base's entrypoint, plus a disabled setup wizard: Google's then finishes
# setup at once, as a redroid container has no one at a screen to go through it.
ENTRYPOINT ["/init", "qemu=1", "androidboot.hardware=redroid", "ro.setupwizard.mode=DISABLED"]
