# Go To

A Spotlight-style popup that finds a file or folder and reveals it in Finder. It reuses your most recent Finder window, or opens a new one if none are open.

## Build & install

```bash
./build.sh --install
```

This compiles `GoTo.app`, copies it to `/Applications` and launches it. It needs only the Xcode Command Line Tools, not the full Xcode. The app runs in the background with a menu bar icon, which you can turn off.

On first launch macOS asks for:
- **Desktop / Documents / Downloads** access, so those folders can be indexed. You can grant Full Disk Access instead.
- **Automation → Finder** the first time you reveal something. This lets the app select items in Finder.
- **Keychain** access for "Go To storage key". This key encrypts the saved index and history.

The app is ad-hoc signed (no developer certificate), so after a rebuild macOS may ask for these again. For the keychain prompt, choose **Always Allow**.

## Hotkey (Karabiner-Elements)

Bind your key to the shell command:

```
open -g goto://toggle
```

Example complex modification (Right ⌘ + Space):

```json
{
  "description": "Go To",
  "manipulators": [{
    "type": "basic",
    "from": { "key_code": "spacebar", "modifiers": { "mandatory": ["right_command"] } },
    "to": [{ "shell_command": "open -g goto://toggle" }]
  }]
}
```

Other URLs: `goto://show`, `goto://show?q=text`, `goto://hide`, `goto://settings`, `goto://reindex`.

## Searching

| Typed | Result |
| --- | --- |
| `pph` (a keyphrase) | Jumps straight to its target |
| `proj` | Fuzzy match against every indexed name (word starts and consecutive letters rank higher) |
| `phil src` | Last word matches the name, earlier words match parent folders |
| `documnets` | Typo-tolerant fallback when nothing matches well |
| `~/Doc…`, `/usr/lo…` | Live path browsing |
| `pph/sub` | Browse inside a keyphrase's folder |
| `pph tmp` | Fuzzy search everything inside a keyphrase's folder, at any depth. Works even if the folder isn't indexed (e.g. on another volume); it's scanned on demand and kept in memory. |

Items you open often are ranked higher. When the box is empty, it shows your recent items.

**Keys:** ↵ reveal · ⌘↵ open (enter the folder, or open the file) · ⇥ complete the path · ↑↓ / ⌃N ⌃P move · ⌘1–8 reveal that result · ⌘K add a keyphrase for the selected result · ⌘C copy the path · ⌘, settings · esc close

## Settings

The settings window has three sections:
- **Keyphrases:** add, edit or remove them, or drop files and folders onto the list.
- **Index:** choose search locations and exclusions (by folder name like `node_modules`, or by path like `~/Library`). You can also include hidden files and rebuild the index.
- **General:** menu bar icon, launch at login, and the hotkey command.

Settings are stored as plain JSON at `~/Library/Application Support/GoTo/config.json`. The encrypted index cache (`index.enc`) and history (`history.enc`) are stored in the same folder.

The index is built in the background with `fts`, cached to disk, and rescanned automatically when files change (FSEvents, at most once a minute). `~/Library` is excluded by default. Add `~/Library/Mobile Documents/com~apple~CloudDocs` as a search location if you want iCloud Drive included.

## Security

| Risk | Mitigation |
| --- | --- |
| The index cache and history would reveal file names in protected folders (Documents, Desktop, …) to any process | Encrypted with AES-GCM using a key in the login keychain. Files are owner-only (0600) and excluded from Time Machine. If keychain access is denied, nothing is saved to disk. |
| Developer commands could be used to make the app list files with its permissions | They live only in `build/goto-tools`. `GoTo.app` ignores command-line arguments. |
| Other processes injecting code to borrow Go To's folder access and Finder control | Signed with the hardened runtime (`DYLD_*` injection is blocked). The only entitlement is Apple Events. |
| AppleScript injection through crafted file names | Paths are passed to a precompiled handler as Apple event parameters and never spliced into script text. |
| A malicious file ranking first and being run with ⌘↵ | Apps, scripts, installers and executables need confirmation, except apps in `/Applications` or `/System` that aren't quarantined. |
| Any app or web page can send `goto://` URLs | URLs can only show or hide UI, pre-fill a query (control characters stripped, 200-character cap) or request a reindex (at most once a minute). Unknown actions are ignored. |
| A corrupted or forged index cache | Every entry is bounds- and structure-checked on load. Anything malformed is discarded and rebuilt. |

`config.json` stays plain text so you can edit it, but it is owner-only.

## Development

```bash
./build.sh
```

This also builds `build/goto-tools`, which is never installed:

```bash
build/goto-tools --selftest
```

This checks the security hardening above: encryption, cache validation (including 5,000 random corruptions), hostile file names, launch confirmation and URL sanitising.

```bash
build/goto-tools --search --root ~/Documents --kp pph=~/Documents "query" "another"
```

This prints index time, ranked results and per-keystroke latency.

```bash
build/goto-tools --snapshot panel.png "query"
```

This renders the panel to an image.

## License

Copyright (C) 2026 absolute-cinema-jpg

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for details.
