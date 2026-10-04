# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# GPU firmware stage: fetch-gpu-firmware. Sourced by scripts/inner.sh.
#
# drm/powervr loads a firmware image named after the GPU's BVNC. This board's is
# 36.56.104.183, read off the silicon (the vendor stack prints "Read BVNC
# 36.56.104.183 from HW device registers"). Upstream linux-firmware carries
# 33.15.11.3, 36.52.104.182 and 36.53.104.796 -- not ours -- and Debian's
# firmware-misc-nonfree carries two of those three, so no distribution delivers
# this file. The only publisher is Imagination's own linux-firmware fork on
# freedesktop.org, fetched here at a pinned commit.
#
# It is NOT the closed vendor DDK blob (rgx.fw.36.56.104.183, a different
# artefact for a different driver); this is the open-stack one, and its WHENCE
# version string says so (1.1.OS@6976702).
#
# LICENCE. LICENSE.powervr in that repository grants redistribution in binary
# form without modification, provided the copyright notice travels with it, and
# forbids reverse engineering. That is why the licence text is fetched as well
# and installed next to the firmware.
#
# What lands in OUT_DIR/gpu-firmware/: the firmware file and LICENSE.powervr.

GPU_FW_PROJECT=22015      # gitlab.freedesktop.org/imagination/linux-firmware
GPU_FW_REF="8a58f81883f7be458daa34e418cc4079f995b279"
GPU_FW_API="https://gitlab.freedesktop.org/api/v4/projects/${GPU_FW_PROJECT}/repository/files"
GPU_FW_NAME="rogue_36.56.104.183_v1.fw"
GPU_FW_SHA="1db1c399c17401d1f79d46c880db81c724d748c784d4639433b076aba2f9c0d2"
GPU_FW_LIC_SHA="1c9aa6bd6703a7ce1cdb879542fa1d8aca115a327bd819b193c971de9c53f402"

pins_gpu_firmware() {
  log "gpu-fw   : ${GPU_FW_NAME} from freedesktop.org project ${GPU_FW_PROJECT} @ ${GPU_FW_REF:0:12}, sha256 ${GPU_FW_SHA:0:16}..."
}

stage_gpu_firmware() {
  local out="${OUT_DIR}/gpu-firmware"
  mkdir -p "${out}"
  fetch_verified "${GPU_FW_SHA}" "${out}/${GPU_FW_NAME}" \
    "${GPU_FW_API}/powervr%2F${GPU_FW_NAME}/raw?ref=${GPU_FW_REF}"
  fetch_verified "${GPU_FW_LIC_SHA}" "${out}/LICENSE.powervr" \
    "${GPU_FW_API}/LICENSE.powervr/raw?ref=${GPU_FW_REF}"
  log "gpu firmware: ${GPU_FW_NAME} and LICENSE.powervr verified -> ${out}"
}

# The same stage under the fetch- name the other groups use.
stage_fetch_gpu_firmware() { stage_gpu_firmware; }
