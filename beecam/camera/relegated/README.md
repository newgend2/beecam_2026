# Relegated Capture Scripts

These scripts are kept for reference only and should not be deployed to the
field cameras during normal updates.

- `beecam_capture_final_original.py`: original capture pipeline. It used
  switch-mode still capture and did not have asynchronous save buffering or
  stale-detection suppression.
- `beecam_capture_final_v2.py`: added same-request main-stream saving with an
  asynchronous save queue, but did not include stale-detection suppression.

The current production capture script lives one directory up as
`beecam_capture_final.py`.
