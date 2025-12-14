import os
import shutil
import zipfile
from tempfile import TemporaryDirectory
from subprocess import run

from frozendict import frozendict

from .common import Common, download_from_cache


class OpenGapps(Common):
    copy_dir_static = "opengapps"

    dl_links = frozendict(
        {
            "x86_64": (
                "https://cfhcable.dl.sourceforge.net/project/opengapps/x86_64/20220503/open_gapps-x86_64-10.0-pico-20220503.zip",
                "5fb186bfb7bed8925290f79247bec4cf",
            ),
            "arm64-v8a": (
                "https://versaweb.dl.sourceforge.net/project/opengapps/arm64/20220503/open_gapps-arm64-10.0-pico-20220503.zip?viasf=1",
                "2feaf25d03530892c6146687ffa08bc2",
            ),
        }
    )

    non_apks = frozenset(
        {
            "defaultetc-common.tar.lz",
            "defaultframework-common.tar.lz",
            "googlepixelconfig-common.tar.lz",
            "vending-common.tar.lz",
        }
    )
    skip = frozenset(
        {"setupwizarddefault-x86_64.tar.lz", "setupwizardtablet-x86_64.tar.lz"}
    )

    def install(self) -> None:
        android_architecture: str
        match self.image_state["architecture"]:
            case "arm64":
                android_architecture = "arm64-v8a"
            case "amd64":
                android_architecture = "x86_64"
        assert android_architecture is not None

        pulled_url, expected_md5 = self.dl_links[android_architecture]

        with TemporaryDirectory() as extract_to:
            with TemporaryDirectory() as download_scratch:
                zipfile_filename = download_from_cache(
                    pulled_url, expected_md5, download_scratch
                )
                with zipfile.ZipFile(download_scratch + os.sep + zipfile_filename) as z:
                    z.extractall(extract_to)

            if not os.path.exists(os.path.join(extract_to, "appunpack")):
                os.makedirs(os.path.join(extract_to, "appunpack"))

            for lz_file in os.listdir(os.path.join(extract_to, "Core")):
                for d in os.listdir(os.path.join(extract_to, "appunpack")):
                    shutil.rmtree(os.path.join(extract_to, "appunpack", d))

                if lz_file not in self.skip:
                    if lz_file not in self.non_apks:
                        run(
                            [
                                "tar",
                                "--lzip",
                                "-xf",
                                os.path.join(extract_to, "Core", lz_file),
                                "-C",
                                os.path.join(extract_to, "appunpack"),
                            ],
                            check=True,
                        )
                        app_name = os.listdir(os.path.join(extract_to, "appunpack"))[0]
                        xx_dpi = os.listdir(
                            os.path.join(extract_to, "appunpack", app_name)
                        )[0]
                        app_priv = os.listdir(
                            os.path.join(extract_to, "appunpack", app_name, "nodpi")
                        )[0]
                        app_src_dir = os.path.join(
                            extract_to, "appunpack", app_name, xx_dpi, app_priv
                        )
                        for app in os.listdir(app_src_dir):
                            shutil.copytree(
                                os.path.join(app_src_dir, app),
                                os.path.join(self.copy_dir, "system", "priv-app", app),
                                dirs_exist_ok=True,
                            )
                    else:
                        run(
                            [
                                "tar",
                                "--lzip",
                                "-xf",
                                os.path.join(extract_to, "Core", lz_file),
                                "-C",
                                os.path.join(extract_to, "appunpack"),
                            ],
                            check=True,
                        )
                        app_name = os.listdir(os.path.join(extract_to, "appunpack"))[0]
                        common_content_dirs = os.listdir(
                            os.path.join(extract_to, "appunpack", app_name, "common")
                        )
                        for ccdir in common_content_dirs:
                            shutil.copytree(
                                os.path.join(
                                    extract_to, "appunpack", app_name, "common", ccdir
                                ),
                                os.path.join(self.copy_dir, "system", ccdir),
                                dirs_exist_ok=True,
                            )


__all__ = ("OpenGapps",)
