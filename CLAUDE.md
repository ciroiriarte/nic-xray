# nic-xray — single-script repository

## 1. Objectives
* Provide detailed physical network interface diagnostics for Linux systems

## 2. Technical Stack & Dependencies
* **Language:** Modern Bash

## 3. Coding Rules & Constraints
* Should use bash native capabilities as much as possible before falling back to external tools
* No magic strings, define variables with default values when required
* Coding style should be unified/standardized
* Options should always handle long and short alternatives.
* Help function must always exist.
* The script must define a `SCRIPT_VERSION` variable near the top (after header comments, before configuration) and support `--version`/`-v` flags that output `nic-xray.sh <version>`. The version must also appear in the `# Version:` header comment and in `--help` output.
* Execution when required parameters are missing must present the user with a usage message.
* Output formatting should be clean & aesthetic, clear to the user.
* Use process bars to allow the user to understand process progress. Implement that only when formatted output is not requested (CSV, JSON, etc)
* Use functions when the script becomes long and complex.

## 4. Documentation
* The man page lives under `man/man8/nic-xray.8` in classic troff/groff format (section 8, system administration commands). It must document at minimum: NAME, SYNOPSIS, DESCRIPTION, OPTIONS, EXIT STATUS, EXAMPLES, AUTHORS, and SEE ALSO.
* The `README.md` must include: Author (Ciro Iriarte), creation date, update date, description, requirements, recommendations, and usage examples.
* Use UTF-8 based icons to make reading easier.
* Format should be consistent.

## 5. Security
* Safe variable handling is required.
* Apply relevant safe coding practices you may know about.

## 6. Releases
* Use semantic versioning (https://semver.org/)
* Bump script version & repo release tags in tandem
