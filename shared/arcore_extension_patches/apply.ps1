# Prepares shared/arcore_extension for building the ARCore plugin:
# checks out the pinned upstream commit (tGautot/godot_arcore), applies our patches from this folder as commits
# on the local branch "samples" and checks out godot-cpp at the version the patches pin.
# Run it after cloning and whenever the patches changed. Local changes in the submodule are discarded,
# so run export.ps1 first if you changed the plugin.
$ErrorActionPreference = 'Stop'
$root = git -C $PSScriptRoot rev-parse --show-toplevel
$sub = Join-Path $root 'shared/arcore_extension'
$patches = (Get-ChildItem (Join-Path $PSScriptRoot '*.patch') | Sort-Object Name).FullName

function Run { & git @args; if ($LASTEXITCODE) { throw "git $args failed" } }

Run -C $root submodule update --init shared/arcore_extension
$pin = (git -C $root ls-files -s shared/arcore_extension).Split()[1]   # pinned upstream commit

# Keep the repository's line endings (LF), otherwise the patches don't apply on Windows.
Run -C $sub config core.autocrlf false
try { git -C $sub am --abort 2>$null } catch {}   # leftover of an earlier failed run, usually none
Run -C $sub switch -q -f -C samples $pin
Run -C $sub am -q --whitespace=nowarn @patches
Run -C $sub submodule update --init --recursive
Write-Host "shared/arcore_extension: upstream $($pin.Substring(0,10)) + $($patches.Count) patches (branch 'samples')."
