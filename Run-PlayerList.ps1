<#
.SYNOPSIS
    Run-PlayerList.ps1 — Run Playbook across multiple repositories sequentially or in parallel.

.DESCRIPTION
    Accepts a list of repo URIs (or local paths) and runs Run-Player.ps1 on each one.
    Supports sequential (default) and parallel execution modes.
    All Run-Player.ps1 parameters can be passed as shared defaults.

.PARAMETER Repos
    Array of repo definitions. Each entry can be:
    - A simple URI string: "https://dev.azure.com/org/project/_git/repo"
    - A simple local path: "C:\Repo\MyRepo"
    - A hashtable with overrides: @{ Url="..."; BaseBranch="main"; Pack="audit" }

.PARAMETER ReposFile
    Path to a JSON file containing the repo list. Format:
    [
      { "Url": "https://...", "BaseBranch": "develop" },
      { "Path": "C:\\Repo\\Local", "Pack": "quick" }
    ]

.PARAMETER Mode
    Execution mode: "sequential" (default) or "parallel".
    Parallel launches all repos as background jobs simultaneously.

.PARAMETER MaxParallel
    Maximum concurrent jobs in parallel mode. Default: 3.

.PARAMETER CloneRoot
    Root directory for cloning repos. Default: C:\Repo

.EXAMPLE
    # Sequential run on two repos
    .\Run-MultiRepo.ps1 -Repos @(
        "https://dev.azure.com/org/project/_git/RepoA",
        "https://dev.azure.com/org/project/_git/RepoB"
    ) -Pack full -QuestionsPerEntry 10 -CommitMode commit

.EXAMPLE
    # Parallel run from a JSON file
    .\Run-MultiRepo.ps1 -ReposFile ".\my-repos.json" -Mode parallel -MaxParallel 2

.EXAMPLE
    # Mix of local and remote repos with per-repo overrides
    .\Run-MultiRepo.ps1 -Repos @(
        @{ Path = "C:\Repo\MyService"; BaseBranch = "develop"; Pack = "full" },
        @{ Url = "https://dev.azure.com/org/proj/_git/MyApi"; Pack = "audit" }
    ) -QuestionsPerEntry 10 -CommitMode commit
#>

[CmdletBinding()]
param(
    # Repo list — strings or hashtables
    [object[]]$Repos,
    [string]$ReposFile,
    [ValidateSet("sequential", "parallel")]
    [string]$Mode = "sequential",
    [int]$MaxParallel = 3,
    [string]$CloneRoot = "C:\Repo",

    # ── Shared defaults (passed to every Run-Player.ps1 unless overridden per-repo) ──
    [string]$BranchName = "feature/copilot-knowledge-layer",
    [string]$BaseBranch,
    [string]$Pack = "full",
    [string]$CommitMode = "dry-run",
    [string]$Model,
    [int]$QuestionsPerEntry,
    [int]$QuestionsPerGap,
    [int]$QuestionsPerFile,
    [int]$GeorgeQuestionsPerDomain,
    [switch]$CreatePR,
    [string]$GitProvider,
    [switch]$HealMode,
    [switch]$ShowVerbose,
    [switch]$ForcePlaybook,
    [string[]]$TargetAgents,
    [int]$MaxRetries = 3,
    [int]$RetryBaseDelay = 30,
    [int]$CallTimeout = 300,
    [int]$BatchSize = 5,
    [switch]$Incremental,
    [string]$Since
)

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptRoot
$OrchestratorPath = Join-Path $ScriptRoot "Run-Player.ps1"

if (-not (Test-Path $OrchestratorPath)) {
    Write-Error "Run-Player.ps1 not found at $OrchestratorPath"
    return
}

# ── Load repos from file if provided ──────────────────────────────────────
if ($ReposFile) {
    if (-not (Test-Path $ReposFile)) {
        Write-Error "Repos file not found: $ReposFile"
        return
    }
    $Repos = Get-Content $ReposFile -Raw | ConvertFrom-Json
}

if (-not $Repos -or $Repos.Count -eq 0) {
    Write-Error "No repos specified. Use -Repos or -ReposFile."
    return
}

# ── Normalize repo entries ────────────────────────────────────────────────
function Normalize-RepoEntry {
    param([object]$Entry)

    if ($Entry -is [string]) {
        if (Test-Path $Entry) {
            return @{ Path = $Entry }
        } else {
            return @{ Url = $Entry }
        }
    }
    if ($Entry -is [hashtable]) { return $Entry }
    # PSCustomObject from JSON
    $ht = @{}
    $Entry.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
    return $ht
}

$NormalizedRepos = @()
foreach ($r in $Repos) {
    $NormalizedRepos += Normalize-RepoEntry $r
}

# ── Build args for a single repo ──────────────────────────────────────────
function Build-MonkeyArgs {
    param([hashtable]$Repo)

    $args = @{ NonInteractive = $true }

    # Repo source — per-repo override or from entry
    if ($Repo.Path) {
        $args.RepoPath = $Repo.Path
    } elseif ($Repo.Url) {
        $args.RepoUrl = $Repo.Url
        # Derive clone path from URL
        $repoName = ($Repo.Url -split '/')[-1] -replace '\.git$', ''
        $args.ClonePath = Join-Path $CloneRoot $repoName
    }

    # Per-repo overrides take priority, then shared defaults
    $paramMap = @{
        BaseBranch              = 'BaseBranch'
        BranchName              = 'BranchName'
        Pack                    = 'Pack'
        CommitMode              = 'CommitMode'
        Model                   = 'Model'
        GitProvider             = 'GitProvider'
        QuestionsPerEntry       = 'QuestionsPerEntry'
        QuestionsPerGap         = 'QuestionsPerGap'
        QuestionsPerFile        = 'QuestionsPerFile'
        GeorgeQuestionsPerDomain = 'GeorgeQuestionsPerDomain'
        BatchSize               = 'BatchSize'
        Since                   = 'Since'
    }

    foreach ($key in $paramMap.Keys) {
        $targetParam = $paramMap[$key]
        if ($Repo.ContainsKey($key) -and $Repo[$key]) {
            $args[$targetParam] = $Repo[$key]
        } elseif ((Get-Variable $key -ErrorAction SilentlyContinue).Value) {
            $args[$targetParam] = (Get-Variable $key).Value
        }
    }

    # Switch params
    $switchMap = @{
        CreatePR      = 'CreatePR'
        HealMode      = 'HealMode'
        ShowVerbose   = 'ShowVerbose'
        ForcePlaybook = 'ForcePlaybook'
        Incremental   = 'Incremental'
    }
    foreach ($key in $switchMap.Keys) {
        $targetParam = $switchMap[$key]
        if ($Repo.ContainsKey($key) -and $Repo[$key]) {
            $args[$targetParam] = $true
        } elseif ((Get-Variable $key -ErrorAction SilentlyContinue).Value) {
            $args[$targetParam] = $true
        }
    }

    # Array params
    if ($Repo.ContainsKey('TargetAgents') -and $Repo.TargetAgents) {
        $args.TargetAgents = $Repo.TargetAgents
    } elseif ($TargetAgents) {
        $args.TargetAgents = $TargetAgents
    }

    # Retry/timeout
    $args.MaxRetries = if ($Repo.ContainsKey('MaxRetries')) { $Repo.MaxRetries } else { $MaxRetries }
    $args.RetryBaseDelay = if ($Repo.ContainsKey('RetryBaseDelay')) { $Repo.RetryBaseDelay } else { $RetryBaseDelay }
    $args.CallTimeout = if ($Repo.ContainsKey('CallTimeout')) { $Repo.CallTimeout } else { $CallTimeout }

    return $args
}

function Get-RepoLabel {
    param([hashtable]$Repo)
    if ($Repo.Path) { return Split-Path $Repo.Path -Leaf }
    if ($Repo.Url)  { return ($Repo.Url -split '/')[-1] -replace '\.git$', '' }
    return "unknown"
}

# ── Banner ────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║  🐒 MULTI-REPO MONKEY ARMY              ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Mode: $Mode | Repos: $($NormalizedRepos.Count) | Pack: $Pack" -ForegroundColor Gray
Write-Host ""

$results = [System.Collections.ArrayList]::new()
$startTime = Get-Date

# ── Sequential mode ───────────────────────────────────────────────────────
if ($Mode -eq "sequential") {
    for ($i = 0; $i -lt $NormalizedRepos.Count; $i++) {
        $repo = $NormalizedRepos[$i]
        $label = Get-RepoLabel $repo
        $num = $i + 1

        Write-Host ""
        Write-Host "  ══════════════════════════════════════════" -ForegroundColor Yellow
        Write-Host "  Repo $num/$($NormalizedRepos.Count): $label" -ForegroundColor Yellow
        Write-Host "  ══════════════════════════════════════════" -ForegroundColor Yellow
        Write-Host ""

        $monkeyArgs = Build-MonkeyArgs $repo
        $repoStart = Get-Date

        try {
            & $OrchestratorPath @monkeyArgs
            $status = "✅ Success"
        } catch {
            Write-Host "  [ERROR] $label failed: $_" -ForegroundColor Red
            $status = "❌ Failed: $($_.Exception.Message)"
        }

        $elapsed = (Get-Date) - $repoStart
        [void]$results.Add(@{
            Repo     = $label
            Status   = $status
            Duration = $elapsed.ToString("hh\:mm\:ss")
        })
    }
}

# ── Parallel mode ─────────────────────────────────────────────────────────
if ($Mode -eq "parallel") {
    $jobs = @{}
    $running = 0
    $queue = [System.Collections.Queue]::new()

    for ($i = 0; $i -lt $NormalizedRepos.Count; $i++) {
        $queue.Enqueue(@{ Index = $i; Repo = $NormalizedRepos[$i] })
    }

    # Launch up to MaxParallel
    function Start-NextJob {
        if ($queue.Count -eq 0) { return }
        $item = $queue.Dequeue()
        $repo = $item.Repo
        $label = Get-RepoLabel $repo
        $monkeyArgs = Build-MonkeyArgs $repo

        Write-Host "  [LAUNCH] $label" -ForegroundColor Cyan

        $job = Start-Job -ScriptBlock {
            param($ScriptPath, $Args)
            & $ScriptPath @Args
        } -ArgumentList $OrchestratorPath, $monkeyArgs

        $jobs[$job.Id] = @{
            Job      = $job
            Label    = $label
            Start    = Get-Date
        }
        $script:running++
    }

    # Initial launch wave
    while ($running -lt $MaxParallel -and $queue.Count -gt 0) {
        Start-NextJob
    }

    # Poll for completions
    while ($jobs.Count -gt 0) {
        Start-Sleep -Seconds 10

        $completedIds = @()
        foreach ($id in $jobs.Keys) {
            $entry = $jobs[$id]
            if ($entry.Job.State -in 'Completed', 'Failed', 'Stopped') {
                $completedIds += $id
            }
        }

        foreach ($id in $completedIds) {
            $entry = $jobs[$id]
            $elapsed = (Get-Date) - $entry.Start

            if ($entry.Job.State -eq 'Completed') {
                $status = "✅ Success"
                try { Receive-Job $entry.Job } catch { }
            } else {
                $status = "❌ $($entry.Job.State)"
                try {
                    $err = Receive-Job $entry.Job -ErrorAction SilentlyContinue 2>&1
                    Write-Host "  [ERROR] $($entry.Label): $err" -ForegroundColor Red
                } catch { }
            }

            Write-Host "  [DONE] $($entry.Label) — $status ($($elapsed.ToString('hh\:mm\:ss')))" -ForegroundColor $(if ($status -match '✅') { 'Green' } else { 'Red' })

            [void]$results.Add(@{
                Repo     = $entry.Label
                Status   = $status
                Duration = $elapsed.ToString("hh\:mm\:ss")
            })

            Remove-Job $entry.Job -Force
            $jobs.Remove($id)
            $script:running--

            # Launch next if queued
            if ($queue.Count -gt 0 -and $running -lt $MaxParallel) {
                Start-NextJob
            }
        }
    }
}

# ── Summary Report ────────────────────────────────────────────────────────
$totalElapsed = (Get-Date) - $startTime

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║  📊 MULTI-REPO SUMMARY                  ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ┌────────────────────────────────────┬────────────┬──────────┐"
Write-Host "  │ Repository                         │ Status     │ Duration │"
Write-Host "  ├────────────────────────────────────┼────────────┼──────────┤"

foreach ($r in $results) {
    $name = $r.Repo.PadRight(34).Substring(0, 34)
    $stat = if ($r.Status -match '✅') { '✅ Pass   ' } else { '❌ Fail   ' }
    Write-Host "  │ $name │ $stat │ $($r.Duration) │"
}

Write-Host "  └────────────────────────────────────┴────────────┴──────────┘"
Write-Host ""

$passed = ($results | Where-Object { $_.Status -match '✅' }).Count
$failed = $results.Count - $passed
Write-Host "  Total: $($results.Count) repos | ✅ $passed passed | ❌ $failed failed | ⏱️ $($totalElapsed.ToString('hh\:mm\:ss'))" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Yellow' })
Write-Host ""
