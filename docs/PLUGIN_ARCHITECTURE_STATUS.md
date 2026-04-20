# Plugin architecture status

## Status
The plugin architecture is **designed and locally packaged**, but was **not previously verified as canonical in the GitHub repo**.

## Target structure
```text
core/
  config.py
  context.py
  logging_utils.py
  plugin_manager.py
  shell.py
  state.py
plugins/
  rclone_plugin.py
  local_index_plugin.py
  case_shield_plugin.py
  future: gmail_plugin.py, drive_plugin.py, dropbox_plugin.py, box_plugin.py, export_plugin.py
```

## Decision
Until the code is committed and validated in this repository, the plugin architecture is not the source of truth.

## Required next step
Commit the upgraded app baseline and align the local Zorin implementation to this repo.

## Design rule
Core orchestration stays generic. Provider-specific logic belongs in plugins. Resource registry updates and awareness exports must be triggered whenever a plugin adds a new remote, service, or local logical unit.
