# findreplace-mdtxt

Native Swift CLI for recursive **Find & Replace** in **.md** and **.txt** files (including subfolders), with GUI dialogs (folder picker + find/replace), history (last 10 entries), and hidden-folder exclusion.

## Features

- Recursive: processes subfolders down to the deepest level
- File types only: **.md** and **.txt**
- **No hidden folders/files** (anything with a `.` prefix is ignored)
- Ignores common repo/build folders (e.g. `.git`, `DerivedData`, `node_modules`, `.swiftpm`, …)
- GUI:
  - Folder picker (NSOpenPanel)
  - “Find / Replace” dialog with two input fields
  - TAB navigation between fields
  - History: remembers the last **10** find/replace pairs
  - “Clear history” button
  - Displays **which folder** is being processed (useful when running in parallel)

## Usage (Command Line)

The tool accepts **files and/or folders** as arguments (e.g. via Finder/Automator/Quick Action).

### Arguments

- **0 arguments**: A folder picker is shown. Then the tool runs recursively in that folder.
- **1..n arguments**:
  - **Folders** → scanned recursively (through all subfolders)
  - **Files** → only those files (if they are .md/.txt)

### Rules

- Only files ending in **.md** or **.txt** are processed.
- Hidden folders/files are not entered/processed.
- If the selection contains no supported files, an info message is shown.

## Automator Quick Action Integration

Goal: Right-click a folder in Finder → Quick Action → the tool starts immediately for that folder.

### Recommended: “Workflow receives”

- **Workflow receives:** “folders” in Finder

### Action: “Run Shell Script”

- Shell: `/bin/zsh` (or `bash`, both are fine)
- Pass input: “as arguments”
- Script content: call the tool **only** (no extra options required)

Important: The selected Finder folder is passed as an argument. The tool detects this and opens the find/replace dialog immediately for that folder.

## License

This project is licensed under the **MIT License** — see **LICENSE**.
