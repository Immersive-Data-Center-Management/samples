# Writes the commits of shared/arcore_extension (branch "samples", on top of the pinned upstream commit)
# back to the *.patch files in this folder. Commit your plugin changes in the submodule first.
$ErrorActionPreference = 'Stop'
$root = git -C $PSScriptRoot rev-parse --show-toplevel
$sub = Join-Path $root 'shared/arcore_extension'

$pin = (git -C $root ls-files -s shared/arcore_extension).Split()[1]
# Must be an upstream commit. An explicit `git add shared/arcore_extension` records our local patch commits instead.
if (-not (git -C $sub branch -r --contains $pin)) {
    throw "The submodule pointer $pin is not an upstream commit (was the submodule staged with git add?). Reset it to the upstream commit the patches are based on: git update-index --cacheinfo 160000,<commit>,shared/arcore_extension"
}
if (git -C $sub status --porcelain --untracked-files=no --ignore-submodules=dirty) { throw 'shared/arcore_extension has uncommitted changes. Commit them in the submodule first.' }

Remove-Item (Join-Path $PSScriptRoot '*.patch')
# Fixed options so that unchanged commits give byte-identical patch files (no hashes, no version signature).
git -C $sub format-patch -q --zero-commit --no-signature --keep-subject -o $PSScriptRoot "$pin..HEAD"
if ($LASTEXITCODE) { throw 'git format-patch failed' }
Write-Host "Exported $((Get-ChildItem (Join-Path $PSScriptRoot '*.patch')).Count) patches. Review them with git diff."
