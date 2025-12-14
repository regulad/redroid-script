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
            "14.0.0": frozendict(
                {
                    "x86_64": (
                        "https://github.com/s1204IT/MindTheGappsBuilder/releases/download/20240226/MindTheGapps-14.0.0-x86_64-20240226.zip",
                        "a827a84ccb0cf5914756e8561257ed13",
                    ),
                    "arm64": (
                        "https://github.com/s1204IT/MindTheGappsBuilder/releases/download/20240226/MindTheGapps-14.0.0-arm64-20240226.zip",
                        "a0905cc7bf3f4f4f2e3f59a4e1fc789b",
                    ),
                }
            ),
            "13.0.0": frozendict(
                {
                    "x86_64": (
                        "https://github.com/s1204IT/MindTheGappsBuilder/releases/download/20240226/MindTheGapps-13.0.0-x86_64-20240226.zip",
                        "eee87a540b6e778f3a114fff29e133aa",
                    ),
                    "arm64": (
                        "https://github.com/s1204IT/MindTheGappsBuilder/releases/download/20240226/MindTheGapps-13.0.0-arm64-20240226.zip",
                        "ebdf35e17bc1c22337762fcf15cd6e97",
                    ),
                }
            ),
            "12.0.0": frozendict(
                {
                    "x86_64": (
                        "https://github.com/s1204IT/MindTheGappsBuilder/releases/download/20240619/MindTheGapps-12.1.0-x86_64-20240619.zip",
                        "05d6e99b6e6567e66d43774559b15fbd",
                    ),
                    "arm64": (
                        "https://github.com/s1204IT/MindTheGappsBuilder/releases/download/20240619/MindTheGapps-12.1.0-arm64-20240619.zip",
                        "94dd174ff16c2f0006b66b25025efd04",
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
