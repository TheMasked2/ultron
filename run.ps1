# Start Ultron. --text: type commands; --dry-run: show detected games.
. "$PSScriptRoot\env.ps1"
& $uv run --project $PSScriptRoot python -m ultron @args
