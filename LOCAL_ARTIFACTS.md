# Local Artifact Cleanup

Date: 2026-05-29

This checkout had local model downloads and a local Python environment that were
removed to recover disk space. The source code, local runner scripts, lockfile,
and download logs are kept in Git.

## Removed local payloads

- `lingbot-world-base-cam/` - 219G total.
- `lingbot-world-base-cam/high_noise_model/` - 70G.
- `lingbot-world-base-cam/low_noise_model/` - 70G.
- `lingbot-world-base-cam/lingbot_world_fast/` - 70G.
- `lingbot-world-base-cam/models_t5_umt5-xxl-enc-bf16.pth` - 11G.
- `lingbot-world-base-cam/Wan2.1_VAE.pth` - 508M.
- `.venv/` - 5.3G local Python environment.

## Preserved metadata

- `logs/model-downloads.log`
- `logs/model-downloads-fast.log`
- `scripts/build_flash_attn_safe.sh`
- `scripts/run_i2v_5090d_fast.sh`
- `scripts/run_i2v_5090d_safe.sh`
- `scripts/run_i2v_720p.sh`
- `uv.lock`

## Re-download commands

Use the Beijing-friendly mirror when needed:

```sh
HF_ENDPOINT=https://hf-mirror.com hf download robbyant/lingbot-world-base-cam --local-dir ./lingbot-world-base-cam
HF_ENDPOINT=https://hf-mirror.com hf download robbyant/lingbot-world-fast --local-dir ./lingbot-world-base-cam/lingbot_world_fast
```

The same base model is also listed in the upstream README as available from
ModelScope under `Robbyant/lingbot-world-base-cam`.
