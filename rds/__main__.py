import subprocess
import argparse
import platform
from os import sep
from sys import stderr
from tempfile import TemporaryDirectory
from warnings import warn

from .state import ImageState
from .modules.opengapps import OpenGapps
from .modules.mindthegapps import MindTheGapps


ANDROID_9_MAJORS = frozenset(
    {"9.0.0", "9.0.0_r220830", "9.0.0_r220709", "9.0.0_r220514", "9.0.0_r220107"}
)

ANDROID_10_MAJORS = frozenset(
    {
        "10.0.0",
        "10.0.0_r220830",
        "10.0.0_r220709",
        "10.0.0_r220514",
        "10.0.0_r220107",
        "10.0.0_r210930",
    }
)

ANDROID_11_MAJORS = frozenset({"11.0.0_r220830", "11.0.0_r221023", "11.0.0"})

ANDROID_LEGACY = ANDROID_9_MAJORS | ANDROID_10_MAJORS | ANDROID_11_MAJORS

ANDROID_12_MAJORS = frozenset({"12.0.0", "12.0.0_64only", "12.0.0_64only_r220830"})

ANDROID_13_MAJORS = frozenset(
    {
        "13.0.0",
        "13.0.0_64only",
        "13.0.0_r220830",
        "13.0.0_r220817",
    }
)

ANDROID_14_MAJORS = frozenset(
    {
        "14.0.0",
        "14.0.0_64only",
    }
)

ANDROID_15_MAJORS = frozenset(
    {
        "15.0.0",
        "15.0.0_64only",
    }
)

ANDROID_16_MAJORS = frozenset(
    {
        "16.0.0",
        "16.0.0_64only",
    }
)

ANDROID_SUPPORTED = (
    ANDROID_12_MAJORS
    | ANDROID_13_MAJORS
    | ANDROID_14_MAJORS
    | ANDROID_15_MAJORS
    | ANDROID_16_MAJORS
)

ANDROID_ALL = ANDROID_LEGACY | ANDROID_SUPPORTED


def main() -> None:
    default_architecture: str
    match platform.machine().lower():
        case "x86_64" | "amd64":
            default_architecture = "amd64"
        case "aarch64" | "arm64":
            default_architecture = "arm64"
        case _:
            default_architecture = "arm64"

    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument(
        "--redroid-image",
        type=str,
        dest="redroid",
        help="Base image of redroid, excluding any tags. "
        "Your docker/podman daemon must be autheticated against this source. "
        "Docker hub allows anonymous access, however it is rate limited.",
        default="docker.io/redroid/redroid",
    )
    parser.add_argument(
        "--android-version",
        type=str,
        dest="android",
        help="Specify the Android version to build. "
        "See valid versions on the tags page of Redroid https://hub.docker.com/r/redroid/redroid/tags",
        default="16.0.0_64only-latest",
    )
    parser.add_argument(
        "--architecture",
        type=str,
        dest="architecture",
        help="Specify the architecture you'd like to build the final image for. "
        "Does not need to match the host you're running on, "
        "but the default is the build host's arch.",
        default=default_architecture,
        choices={"arm64", "amd64"},
    )

    parser.add_argument(
        "--gapps",
        type=str,
        dest="gapps",
        help="Installs a GMS provider into the final image. "
        "You will need to experiment to find the best provider for you, "
        "but mindthegapps is STRONGLY reccomended for stability.",
        default=None,
        choices={"opengapps", "mindthegapps"},
    )

    args = parser.parse_args()

    android_major, redroid_revision = args.android.split("-")
    android_features = frozenset(android_major.split("_")[1:])
    base_redroid_tag = f"{args.redroid}:{args.android}"
    docker_platform = f"linux/{args.architecture}"

    if android_major not in ANDROID_ALL:
        raise ValueError("This version of android is not supported by this script.")

    if android_major in ANDROID_LEGACY:
        warn(
            "The Android version you are requesting to build is considered legacy and no longer recieves security updates. "
            "Please update ASAP.",
            DeprecationWarning,
        )
    elif "64only" not in android_features:
        warn(
            "Creating an image that runs in mixed mode (capable of executing both 32-bit and 64-bit binaries) is unsupported. "
            "Please update your workflow to use 64only images ASAP.",
            DeprecationWarning,
        )

    print(
        f"Using {docker_platform} {base_redroid_tag} revision {redroid_revision} as base image",
        file=stderr,
        flush=True,
    )
    subprocess.run(
        [
            "/usr/bin/docker",
            "image",
            "pull",
            f"--platform={docker_platform}",
            base_redroid_tag,
        ],
        stdin=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
        stdout=stderr,
        check=True,
        )

    with TemporaryDirectory() as tempdir:
        # Putting this into a serializable form so it can be accelerated by spawning multiple processes
        image_state: ImageState = {
            "architecture": args.architecture,
            "android_major": android_major,
            "tempdir": tempdir,
        }

        # Specify newline as \n explicitly in case this script is running from an environment that uses \r\n
        # Docker daemon always expects \n. Example: some WSL 1 distros
        with open(tempdir + sep + "Dockerfile", "tw", newline="\n") as dockerfile_fp:
            tag_modifiers: list[str] = []
            dockerfile_fp.write(f"FROM {base_redroid_tag}\n")
            tag_modifiers.append("patched")

            match args.gapps:
                case "opengapps":
                    if (
                        android_major
                        not in ANDROID_9_MAJORS | ANDROID_10_MAJORS | ANDROID_11_MAJORS
                    ):
                        raise ValueError(
                            "OpenGapps only supports max Android 11. Future versions must use a different GMS."
                        )
                    opengapps = OpenGapps(image_state)
                    opengapps.install()
                    dockerfile_fp.write(f"COPY {opengapps.copy_dir_static} /\n")
                    tag_modifiers.append(opengapps.copy_dir_static)
                case "mindthegapps":
                    if (
                        android_major
                        not in ANDROID_14_MAJORS | ANDROID_15_MAJORS
                    ):
                        raise ValueError(
                            "MindTheGapps (or this script's MindTheGapps subsystem) does not support this version of Android."
                        )
                    mtg = MindTheGapps(image_state)
                    mtg.install()
                    dockerfile_fp.write(f"COPY {mtg.copy_dir_static} /\n")
                    tag_modifiers.append(mtg.copy_dir_static)

        patched_redroid_tag = f"{args.redroid}:{android_major}_{'_'.join(tag_modifiers)}-{redroid_revision}"
        subprocess.run(
            ["/usr/bin/docker", "buildx", "build", "-t", patched_redroid_tag, tempdir],
            stdin=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
            stdout=stderr,
            check=True,
        )
        print(patched_redroid_tag)  # only thing printed into stdout for pipeline


if __name__ == "__main__":
    main()
