# aws-me

A lightweight Bash utility for managing multiple AWS CLI profiles with MFA authentication, shared session caching, session monitoring, and easy profile switching.

Designed for administrators working with multiple AWS accounts and IAM roles without manually exporting temporary credentials.

## Features

- Switch between multiple AWS CLI profiles.
- MFA authentication with visible code input.
- Reuse cached AWS sessions across terminal windows.
- Display the currently selected profile and remaining session time.
- List all active cached sessions.
- Log out of individual profiles or clear all cached sessions.
- Bash tab completion for profiles, commands, and active sessions.
- Automatic AWS CLI command completion when `aws_completer` is available.

## Requirements

The following packages are required:

- **Bash** — Shell and programmable completion support.
- **AWS CLI v2** — AWS authentication, AssumeRole, and session caching.
- **jq** — JSON processing.
- **AWK** — AWS profile configuration parsing.
- **GNU coreutils** — Date and time calculations.
- **Expect** — Interactive MFA prompt handling.
- **bash-completion** — Additional Bash completion support.

### Arch Linux

```bash
sudo pacman -S bash aws-cli-v2 jq gawk coreutils expect bash-completion
```

### Debian / Ubuntu

```bash
sudo apt update
sudo apt install bash jq gawk coreutils expect bash-completion
```

Install AWS CLI v2 using the [official AWS installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).

Verify the installation:

```bash
aws --version
expect -v
jq --version
```

**Note:** `aws-me` uses Bash's built-in programmable completion. The `bash-completion` package is recommended for a complete shell completion environment but is not strictly required by `aws-me` itself.

## Installation

Clone the repository:

```bash
git clone https://github.com/dobrildobrilov/aws-me.git
cd aws-me
```

Copy the script:

```bash
mkdir -p ~/.config/bash
cp aws-me.sh ~/.config/bash/aws-me.sh
```

Add the following line to your `~/.bashrc`:

```bash
source ~/.config/bash/aws-me.sh
```

Reload your shell:

```bash
source ~/.bashrc
```

The script must be sourced, not executed as a standalone process, because it modifies the current shell's AWS environment.

## AWS Configuration

Configure your IAM user credentials in `~/.aws/credentials`:

```ini
[company-base]
aws_access_key_id = YOUR_ACCESS_KEY_ID
aws_secret_access_key = YOUR_SECRET_ACCESS_KEY
```

Configure an AssumeRole profile in `~/.aws/config`:

```ini
[profile company-security-admin]
source_profile = company-base
role_arn = arn:aws:iam::123456789012:role/SecurityAdmin
mfa_serial = arn:aws:iam::123456789012:mfa/your-device
role_session_name = security-admin
duration_seconds = 14400
region = eu-central-1
```

Repeat these configurations for additional AWS accounts.

**Important:** Set `role_session_name` explicitly for each role profile. It is used to identify cached sessions and support session monitoring and logout operations.

## Usage

### Select a profile

```bash
aws-me company-security-admin
```

If a valid cached session exists, it is reused automatically. Otherwise, AWS CLI requests an MFA code.

Switch to another profile at any time:

```bash
aws-me another-company-security-admin
```

You do not need to run `--unset` before switching profiles.

### Show the current profile

```bash
aws-me
```

Displays the currently selected AWS profile and its remaining session lifetime.

### List active sessions

```bash
aws-me --sessions
```

Example output:

```text
PROFILE                  ACCOUNT        REMAINING
-------                  -------        ---------
company-security-admin   123456789012   03h 42m 18s

Active sessions: 1
```

This command reads the local AWS CLI cache without contacting AWS or requesting MFA.

### Unset the current profile

```bash
aws-me --unset
```

Clears the AWS profile selection from the current terminal without deleting cached sessions.

### Log out of a specific profile

```bash
aws-me --logout company-security-admin
```

Removes the matching cached AssumeRole session.

### Log out of all profiles

```bash
aws-me --logout-all
```

Removes all cached AWS CLI AssumeRole sessions.

This also affects cached AssumeRole sessions created outside `aws-me`.

## Bash Completion

Bash completion is automatically registered when the script is sourced.

Complete configured profiles and available options:

```text
aws-me <TAB><TAB>
```

Complete only profiles with active cached sessions:

```text
aws-me --logout <TAB><TAB>
```

The completion logic reads local AWS configuration and session cache data. It does not trigger MFA authentication.

If `aws_completer` is available and completion for the `aws` command has not already been configured, the script also registers AWS CLI completion.

## Session Caching

AWS CLI stores cached AssumeRole credentials in:

```text
~/.aws/cli/cache/
```

These sessions are shared between terminal windows running under the same operating system user.

The cache is managed by AWS CLI. `aws-me` provides convenient access to profile selection, session inspection, and cache cleanup.

## Security Notes

- Never commit AWS access keys, temporary credentials, MFA codes, or session cache files.
- Keep `~/.aws/credentials` and AWS cache files accessible only to your user.
- MFA codes are visible while typing; avoid entering them while your terminal is being observed or recorded.
- Removing cached sessions does not revoke previously issued AWS STS credentials. They may remain valid until expiration.
- `--unset` does not guarantee that AWS access is disabled, because the default AWS credential chain may still provide credentials.

## License

MIT License
