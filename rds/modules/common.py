import hashlib
import os
import sys
import subprocess
import warnings
from abc import ABC
from pathlib import Path

from platformdirs import user_cache_dir
from pyrfc6266 import requests_response_to_filename
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from ..state import ImageState


APP_NAME = "rds"
APP_AUTHOR = "ayasa520"


def copy_file(src: Path, dst: Path) -> None:
    """
    Copy a file from source to destination using platform-optimized methods.

    Uses copy-on-write (reflink) when available on Linux, clonefile on macOS,
    and falls back to standard copy operations otherwise.

    Args:
        src: Source file path
        dst: Destination file path

    Raises:
        subprocess.CalledProcessError: If the copy operation fails
        FileNotFoundError: If the source file doesn't exist
    """
    src_str = str(src)
    dst_str = str(dst)

    if sys.platform == "win32":
        subprocess.run(
            [
                "robocopy",
                src.parent,
                dst.parent,
                src.name,
                "/DCOPY:DAT",
                "/COPY:DAT",
                "/R:3",
                "/W:1",
            ],
            check=False,  # robocopy returns non-zero exit codes for success
            stdin=subprocess.DEVNULL,
            stdout=sys.stderr,
            stderr=subprocess.STDOUT,
        )
        # robocopy returns 0-7 for various success conditions, 8+ for errors
        result = subprocess.run(
            [
                "robocopy",
                str(src.parent),
                str(dst.parent),
                src.name,
                "/DCOPY:DAT",
                "/COPY:DAT",
                "/R:3",
                "/W:1",
                "/NJH",
                "/NJS",
            ],
            stdin=subprocess.DEVNULL,
            stdout=sys.stderr,
            stderr=subprocess.STDOUT,
        )
        if result.returncode >= 8:
            raise subprocess.CalledProcessError(result.returncode, result.args)
    elif sys.platform == "linux":
        subprocess.run(
            ["cp", "--reflink=auto", "--preserve=all", src_str, dst_str],
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=sys.stderr,
            stderr=subprocess.STDOUT,
        )
    elif sys.platform == "darwin":
        subprocess.run(
            ["cp", "-c", "-p", src_str, dst_str],
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=sys.stderr,
            stderr=subprocess.STDOUT,
        )
    else:
        subprocess.run(
            ["cp", "-p", src_str, dst_str],
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=sys.stderr,
            stderr=subprocess.STDOUT,
        )


def download_with_md5(
    url: str, expected_md5: str, output_folder: str, chunk_size: int = 8192
) -> str:
    """
    Does what it says on the tin.
    Obeys content-disposition and returns the filename thereof.
    The file will be written into that filename
    """
    # Setup retry strategy
    session = requests.Session()
    retry = Retry(total=3, backoff_factor=0.3)
    adapter = HTTPAdapter(max_retries=retry)
    session.mount("http://", adapter)
    session.mount("https://", adapter)

    # Download with streaming MD5
    md5_hash = hashlib.md5()
    response = session.get(url, stream=True)
    response.raise_for_status()

    filename = requests_response_to_filename(response)
    output_path = output_folder + os.sep + filename

    with open(output_path, "wb") as f:
        for chunk in response.iter_content(chunk_size=chunk_size):
            if chunk:
                md5_hash.update(chunk)
                f.write(chunk)

    actual_md5 = md5_hash.hexdigest()
    if actual_md5 != expected_md5:
        raise ValueError(f"MD5 mismatch: expected {expected_md5}, got {actual_md5}")
    return filename


def download_from_cache(
    url: str,
    expected_md5: str,
    output_folder: str,
    *,
    readonly: bool = False,
    skipcheck: bool = False,
) -> str:
    """
    Downloads an item, opportunistically using the user's cache if possible.
    The returned str is the filename within the output_folder.
    """
    # If this flag is set, then we will not attempt caching.
    abort_caching = False

    cache_directory = user_cache_dir(APP_NAME, APP_AUTHOR)
    output_path = Path(output_folder)
    cache_path = Path(cache_directory)
    cache_container = cache_path / expected_md5
    if cache_container.exists():
        # Cache candidate exists.
        # Let's try to see if a file exists, and if it matches the expected checksum.
        maybe_cached_file: Path | None = None
        if os.access(cache_container, os.R_OK | os.X_OK):
            for child in cache_container.iterdir():
                # This should let us throw if more than one file exists.
                if maybe_cached_file is not None:
                    # More than one file exists in this directory! Invalid!
                    maybe_cached_file = None
                    abort_caching = True
                    warnings.warn(
                        "More than one file was in the cache container. Hash collision?",
                        RuntimeWarning,
                    )
                    break
                if child.exists() and child.is_file() and os.access(child, os.R_OK):
                    maybe_cached_file = child
                else:
                    # We got one file, and it was invalid.
                    abort_caching = True
                    warnings.warn(
                        "A cache container exists, and its file had bad permissions!",
                        RuntimeWarning,
                    )
                    break
        else:
            abort_caching = True
            warnings.warn(
                "A cache container exists, but had invalid permissions! Will need to redownload.",
                RuntimeWarning,
            )
        if maybe_cached_file is not None and not skipcheck:
            # This file passed the permissions checks.
            # Let's see if it passes the checksum check.
            with open(maybe_cached_file, "rb") as cached_file_fp:
                hexdigest_of_cached_file = hashlib.file_digest(
                    cached_file_fp, "md5"
                ).hexdigest()
            if hexdigest_of_cached_file != expected_md5:
                # Even if we have write permissions, there's no guarantee we have delete permissions.
                # It's a lot more important here that we get a final file than we have perfect caching.
                abort_caching = True
                warnings.warn("Cached file did not match expected md5. Redownloading.")
                maybe_cached_file = None
        if maybe_cached_file is not None:
            # Ok, at this point we have a cached file that is confirmed good, confirmed readable, and ready to copy.
            # Let's do this asap so the backing file doesn't change in the meantime. (possible race conditions
            destination_filename = maybe_cached_file.name
            destination_path = output_path / destination_filename
            copy_file(maybe_cached_file, destination_path)
            return destination_filename

    # If we had a cached file, we would have returned by now.
    if readonly:
        raise RuntimeError(
            "This function was called readonly, but the cache was unreadable."
        )

    # Now we have to get the file ourselves.
    # If we have sufficient permissions to make a cache file, we'll write to that first and then copy.
    # Else, just read into final directory (probably tmp)
    if not cache_path.exists() and not abort_caching:
        if (
            os.access(cache_path.parent, os.W_OK | os.R_OK | os.X_OK)
            and not os.statvfs(cache_path.parent).f_flag & os.ST_RDONLY
        ):
            cache_path.mkdir()
        else:
            warnings.warn(
                "Unable to create a cache folder. Will just download without cache.",
                RuntimeWarning,
            )
            abort_caching = True
    if not cache_container.exists() and not abort_caching:
        if (
            os.access(cache_container.parent, os.W_OK | os.R_OK | os.X_OK)
            and not os.statvfs(cache_container.parent).f_flag & os.ST_RDONLY
        ):
            cache_container.mkdir()
        else:
            warnings.warn(
                "Unable to create a cache container. Will download without caching.",
                RuntimeWarning,
            )
            abort_caching = True
    if not abort_caching and not (
        os.access(cache_container, os.W_OK | os.R_OK | os.X_OK)
        and not os.statvfs(cache_container).f_flag & os.ST_RDONLY
    ):
        # Final check.
        warnings.warn("Can't write into the cache container. Won't cache.")
        abort_caching = True

    if not abort_caching:
        # The cache container has been created. Before we download into it, check...
        #     that it is mounted read/write
        #     that we have permissions to write into it
        # NOTE: A recursive control flow is weird here, but it would work, wouldn't it?
        downloaded_file = download_with_md5(url, expected_md5, str(cache_container))
        warmcache_file = download_from_cache(
            url, expected_md5, output_folder, readonly=True, skipcheck=False
        )
        assert downloaded_file == warmcache_file
        return downloaded_file
    else:
        return download_with_md5(url, expected_md5, output_folder)


class Common(ABC):
    # This is the final directory in the image_state["tempdir"] where the docker builder can expect
    # to find the filesystem override.
    copy_dir_static: str

    def __init__(self, image_state: ImageState) -> None:
        self.image_state = image_state
        self.copy_dir = image_state["tempdir"] + os.sep + self.copy_dir_static

    def install(self) -> None:
        raise NotImplementedError


__all__ = (
    "download_from_cache",
    "Common",
)
