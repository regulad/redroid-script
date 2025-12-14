import os
import shutil
import zipfile
from tempfile import TemporaryDirectory

from frozendict import frozendict

from .common import Common, download_from_cache


class MindTheGapps(Common):
    copy_dir_static = "mindthegapps"

    dl_links = frozendict(
        {
            "15.0.0": frozendict(
                {
                    "arm64": (
                        "https://github.com/s1204IT/MindTheGappsBuilder/releases/download/20250330/MindTheGapps-15.0.0-arm64-20250330.zip",
                        "79acb62f0f7c66b0f0bcadae5624f3d1",
                    ),
                }
            ),
            "14.0.0": frozendict(
                {
                    "x86_64": (
                        "https://github.com/s1204IT/MindTheGappsBuilder/releases/download/20250330/MindTheGapps-14.0.0-x86_64-20250330.zip",
                        "f9da567989d18aa33d51cf6faa385798",
                    ),
                    "arm64": (
                        "https://github.com/s1204IT/MindTheGappsBuilder/releases/download/20250330/MindTheGapps-14.0.0-arm64-20250330.zip",
                        "5cf957fb34957153ea8623b37ccf5fcb",
                    ),
                }
            ),
        }
    )

    def install(self) -> None:
        android_architecture: str
        match self.image_state["architecture"]:
            case "arm64":
                android_architecture = "arm64"
            case "amd64":
                android_architecture = "x86_64"
        assert android_architecture is not None

        download_urls_by_architecture = self.dl_links[
            self.image_state["android_major"].split("_")[0]
        ]
        if android_architecture not in download_urls_by_architecture.keys():
            raise ValueError("amd64 is not supported in newer versions of MindTheGapps. Switch to arm64.")
        download_url, expected_md5 = download_urls_by_architecture[android_architecture]

        with TemporaryDirectory() as extract_to:
            with TemporaryDirectory() as download_scratch:
                zipfile_filename = download_from_cache(
                    download_url, expected_md5, download_scratch
                )
                with zipfile.ZipFile(download_scratch + os.sep + zipfile_filename) as z:
                    z.extractall(extract_to)

            shutil.copytree(
                os.path.join(
                    extract_to,
                    "system",
                ),
                os.path.join(self.copy_dir, "system"),
                dirs_exist_ok=True,
            )


__all__ = ("MindTheGapps",)
