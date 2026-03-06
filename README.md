# DevOps Scripts Repository

A collection of useful scripts for DevOps activities, automation, and system administration. This repository includes scripts written in **Bash**, **Python**, and other scripting languages to streamline operations.

## � Available Scripts

| Script Name | Description | Directory |
| :--- | :--- | :--- |
| **Compare Files** | A Python utility to find unique lines between two text files. | [`compare-files/`](./compare-files/) |

---

## 🔍 Script Details

### ⚖️ Compare Files
This script helps in comparing two text files and identifying items that are unique to each file. It's particularly useful for comparing logs, configuration files, or data exports.

#### Usage
1. Open [`compare_files.py`](./compare-files/compare_files.py).
2. Update the `file1` and `file2` paths in the `if __name__ == "__main__":` block.
3. Run the script:
   ```bash
   python compare-files/compare_files.py
   ```

---

## 🚀 Adding New Scripts
To add a new script to this repository:
1. Create a new directory for your script.
2. Add your scripts/files into that directory.
3. Update this `README.md` by:
    - Adding an entry to the **Available Scripts** table.
    - Adding a section under **Script Details** with usage instructions.
