from typing import Literal, TypedDict


class ImageState(TypedDict):
    architecture: Literal["amd64"] | Literal["arm64"]
    android_major: str
    tempdir: str

__all__ = (
    "ImageState",
)

