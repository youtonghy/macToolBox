#!/bin/sh
set -eu

version="1.24.3"
archive_name="onnxruntime-osx-arm64-${version}.tgz"
archive_url="https://github.com/microsoft/onnxruntime/releases/download/v${version}/${archive_name}"
archive_sha256="c255663d40755f84b1b86373bdb9870bb65f3a2c3d779b3d7ae31aaa00cebb4f"
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_dir="${project_dir}/.build/ocr-runtime"
ready_file="${runtime_dir}/.ready-${version}"

if [ -f "${ready_file}" ] \
    && [ -f "${runtime_dir}/include/onnxruntime_ep_c_api.h" ] \
    && [ -f "${runtime_dir}/lib/libonnxruntime.1.24.3.dylib" ]; then
    exit 0
fi

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-ocr-runtime.XXXXXX")
trap 'rm -rf "${temporary_dir}"' EXIT HUP INT TERM
archive_path="${temporary_dir}/${archive_name}"

curl --fail --location --proto '=https' --tlsv1.2 --output "${archive_path}" "${archive_url}"
actual_sha256=$(shasum -a 256 "${archive_path}" | awk '{print $1}')
if [ "${actual_sha256}" != "${archive_sha256}" ]; then
    echo "ONNX Runtime archive checksum mismatch" >&2
    exit 1
fi

tar -xzf "${archive_path}" -C "${temporary_dir}"
extracted_dir="${temporary_dir}/onnxruntime-osx-arm64-${version}"
staging_dir="${runtime_dir}.staging.$$"
rm -rf "${staging_dir}"
mkdir -p "${staging_dir}/include" "${staging_dir}/lib"
cp "${extracted_dir}"/include/*.h "${staging_dir}/include/"
cp "${extracted_dir}/lib/libonnxruntime.1.24.3.dylib" "${staging_dir}/lib/"
ln -s "libonnxruntime.1.24.3.dylib" "${staging_dir}/lib/libonnxruntime.dylib"
touch "${staging_dir}/.ready-${version}"

rm -rf "${runtime_dir}"
mv "${staging_dir}" "${runtime_dir}"
